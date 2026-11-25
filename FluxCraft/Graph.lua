local _, FC = ...
local L = FC.L
local Graph = {}
FC.Graph = Graph

local WIDTH, HEIGHT = 186, 32
local OUTPUT_WIDTH, OUTPUT_HEIGHT = 214, 46
local PRICED_OUTPUT_WIDTH, PRICED_OUTPUT_HEIGHT = 232, 62
local X_STEP, Y_STEP = 206, 70

-- Layout reads the plan only. Occurrences share allocations in that plan, while
-- retaining independent fold state and hit regions.
function Graph.Layout(root, collapsed, compactWidth, showOutputPrices)
    local cards, leaves, cursor, width, height = {}, 0, 8, WIDTH, HEIGHT
    local outputWidth = showOutputPrices and PRICED_OUTPUT_WIDTH or OUTPUT_WIDTH
    local outputHeight = showOutputPrices and PRICED_OUTPUT_HEIGHT or OUTPUT_HEIGHT
    local function visit(node, path, depth, parent)
        local output = not parent
        local card = {node = node, path = path, parent = parent, y = depth * Y_STEP + 12,
            width = output and outputWidth or WIDTH, height = output and outputHeight or HEIGHT}
        if compactWidth then
            local indent = depth * 14
            card.width = output and compactWidth or math.max(138, compactWidth - math.max(32, indent + 8))
            card.x, card.y = 12 + indent, cursor
            cursor = cursor + card.height + 3
        end
        cards[#cards + 1] = card
        local children = node.children or {}
        card.branch = #children > 0
        if #children == 0 or collapsed[path] then
            if not compactWidth then card.x = leaves * X_STEP + 22 end
            leaves = leaves + 1
        else
            local first, last
            for i, child in ipairs(children) do
                local nested = visit(child, path .. "/" .. i .. "-" .. tostring(child.itemID), depth + 1, card)
                local center = nested.x + nested.width / 2
                first, last = first or center, center
            end
            if not compactWidth then card.x = (first + last - card.width) / 2 end
        end
        width, height = math.max(width, card.x + card.width + 12), math.max(height, card.y + card.height + 12)
        return card
    end
    if root then visit(root, tostring(root.itemID), 0) end
    return cards, width, height
end

local function color(texture, r, g, b, a)
    if texture.SetColorTexture then texture:SetColorTexture(r, g, b, a)
    else texture:SetTexture(r, g, b, a) end
end

local function label(frame, font)
    local text = frame:CreateFontString(nil, "OVERLAY", font)
    text:SetJustifyH("LEFT")
    text:SetWordWrap(false)
    return text
end

function Graph.SourceLabel(node)
    local parts = {}
    for _, craft in ipairs(node.crafts or {}) do
        local count = craft.executions or craft.count or craft.craftCount
        if count then parts[#parts + 1] = L.sourceFrom:format(L.Make, count * (craft.yield or node.yield or 1)) end
    end
    if #parts == 0 and (node.craftCount or 0) > 0 then
        parts[#parts + 1] = L.sourceFrom:format(L.Make, node.craftCount * (node.yield or 1))
    end
    for _, purchase in ipairs(node.purchases or {}) do
        local name = purchase.kind == "bank" and L.Bank or purchase.kind == "vendor" and L.Vendor or L.Buy
        parts[#parts + 1] = L.sourceFrom:format(name, purchase.purchased or purchase.quantity or 0)
    end
    if not node.purchases and (node.buy or 0) > 0 then
        parts[#parts + 1] = L.sourceFrom:format(L.Buy, node.buy)
    end
    return #parts > 0 and table.concat(parts, " + ") or L[node.source] or L.unknown
end

function Graph.OutputAmount(recipe, summary)
    local total = summary and summary.output
    if type(total) ~= "number" or total < 1 or total % 1 ~= 0 then return end
    local minimum, maximum = recipe and recipe.yield, recipe and recipe.yieldMax
    local executions = summary.executions
    if type(minimum) == "number" and minimum > 0 and minimum % 1 == 0 and type(maximum) == "number"
        and maximum > minimum and maximum % 1 == 0 and type(executions) == "number" and executions > 0 then
        return L.recipeYieldRange:format(total, total + executions * (maximum - minimum))
    end
    return ("%d"):format(total)
end

local function makeCard(view)
    local button = CreateFrame("Button", nil, view.frame)
    button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    button:EnableMouseWheel(true)
    local edge = button:CreateTexture(nil, "BACKGROUND")
    edge:SetAllPoints()
    button.edge = edge
    local fill = button:CreateTexture(nil, "BORDER")
    fill:SetPoint("TOPLEFT", 1, -1)
    fill:SetPoint("BOTTOMRIGHT", -1, 1)
    button.fill = fill
    local focus = button:CreateTexture(nil, "HIGHLIGHT")
    focus:SetAllPoints()
    color(focus, 0.75, 0.53, 0.18, 0.15)
    button.icon = button:CreateTexture(nil, "ARTWORK")
    button.count = label(button, "NumberFontNormalSmall")
    button.count:SetJustifyH("RIGHT")
    button.count:SetPoint("BOTTOMRIGHT", button.icon, "BOTTOMRIGHT", -1, 0)
    button.name = label(button, "GameFontNormal")
    button.source = label(button, "GameFontHighlightSmall")
    button.source:SetJustifyH("RIGHT")
    button.source:SetTextColor(0.77, 0.73, 0.67)
    button.cost = label(button, "GameFontHighlight")
    button.fold = CreateFrame("Button", nil, button, "UIPanelButtonTemplate")
    button.fold:SetSize(15, 15)
    button.fold:SetPoint("RIGHT", -3, 0)
    button.fold:SetScript("OnClick", function() view:Toggle(button.entry.path) end)
    button:SetScript("OnClick", function(self, mouse)
        if mouse == "RightButton" and button.entry.branch then
            view:Toggle(button.entry.path)
            return
        end
        view.onSelect(button.entry.node, button.entry.path, self)
    end)
    button:SetScript("OnMouseWheel", function(_, delta) view:Scroll(delta) end)
    button:SetScript("OnEnter", function(self) view:ShowTooltip(self) end)
    button:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
    return button
end

local function styleCard(card, output)
    if card.outputStyle == output then return end
    card.outputStyle = output
    card.costNode = nil
    local iconSize = output and 30 or 21
    card.icon:ClearAllPoints()
    card.icon:SetSize(iconSize, iconSize)
    card.icon:SetPoint("LEFT", 6, 0)
    card.fold:ClearAllPoints()
    if output then card.fold:SetPoint("TOPRIGHT", -3, -2)
    else card.fold:SetPoint("RIGHT", -3, 0) end
    if output then color(card.fill, 0.175, 0.129, 0.079, 1)
    else color(card.fill, 0.09, 0.07, 0.055, 1) end
end

local function placeCaption(card, width, branch, text, node, prices)
    local left, right = card.outputStyle and 42 or 33, branch and 23 or 7
    local outputPrices = card.outputStyle and prices
    local showCost = not card.outputStyle or not not outputPrices
    local leftPoint = showCost and "TOPLEFT" or "LEFT"
    local rightPoint = showCost and "TOPRIGHT" or "RIGHT"
    local y = showCost and -3 or 0
    local available = width - left - right
    card.cost:SetShown(showCost)
    if card.outputStyle then
        if outputPrices then
            if card.cost:GetText() ~= outputPrices.cost then card.cost:SetText(outputPrices.cost) end
            card.auction = card.auction or label(card, "GameFontHighlight")
            if card.auction:GetText() ~= outputPrices.auction then card.auction:SetText(outputPrices.auction) end
            card.auction:ClearAllPoints()
            card.auction:SetPoint("BOTTOMLEFT", left, 4)
            card.auction:SetPoint("BOTTOMRIGHT", -7, 4)
        end
    else
        if card.costNode ~= node or card.costWidth ~= available then
            card.costNode, card.costWidth = node, available
            local value, unit, average = node.fullValue, FC.Pricing.MaterialUnitPrice(node)
            local total = value ~= nil and FC.Pricing.FormatCopper(value) or L.unknown
            if unit then
                local perItem = FC.Pricing.FormatCopper(unit)
                local unitText = (average and L.materialUnitAverage or L.materialUnit):format(perItem)
                card.cost:SetText(total ~= perItem and L.materialCostPair:format(total, unitText) or unitText)
                local measure = card.cost.GetUnboundedStringWidth or card.cost.GetStringWidth
                if measure and measure(card.cost) > available then card.cost:SetText(unitText) end
            else
                card.cost:SetText(total)
            end
        end
    end
    if card.auction then card.auction:SetShown(not not outputPrices) end
    if showCost then
        local bottom = outputPrices and 20 or 3
        card.cost:ClearAllPoints()
        card.cost:SetPoint("BOTTOMLEFT", left, bottom)
        card.cost:SetPoint("BOTTOMRIGHT", outputPrices and -7 or -right, bottom)
    end
    card.source:SetText(text)
    local sourceWidth = card.source.GetStringWidth and card.source:GetStringWidth() or #text * 6
    local nameWidth = card.name.GetStringWidth and card.name:GetStringWidth() or nil
    local minimumName = nameWidth and math.min(nameWidth, available * 0.66) or available * 0.66
    local showSource = sourceWidth > 0 and minimumName + sourceWidth + 8 <= available
    card.source:SetShown(showSource)
    if showSource then
        card.source:ClearAllPoints()
        card.source:SetPoint(rightPoint, -right, y)
        right = right + sourceWidth + 8
    end
    card.name:ClearAllPoints()
    card.name:SetPoint(leftPoint, left, y)
    card.name:SetPoint(rightPoint, -right, y)
end

function Graph.ClampPan(viewWidth, viewHeight, graphWidth, graphHeight, scale, x, y)
    local minX = math.min(0, viewWidth - graphWidth * scale)
    local minY = math.min(0, viewHeight - graphHeight * scale)
    return math.max(minX, math.min(0, x or 0)), math.max(minY, math.min(0, y or 0))
end

function Graph:SavePosition()
    self.position.x, self.position.y = self.x, self.y
    self.position.zoom = self.zoom
end

function Graph:Scroll(delta)
    if IsControlKeyDown and IsControlKeyDown() then
        self:Zoom(delta * 0.12)
    elseif IsShiftKeyDown and IsShiftKeyDown() then
        self:Pan(delta * 38, 0)
    else
        self:Pan(0, delta * 38)
    end
end

local function move(view, dx, dy)
    if dx == 0 and dy == 0 then return false end
    local width, height = view.frame:GetSize()
    if not width or width < 1 or not height or height < 1 then return false end
    local x, y = Graph.ClampPan(width, height, view.width, view.height, view.zoom, view.x + dx, view.y + dy)
    if x == view.x and y == view.y then return false end
    view.x, view.y = x, y
    view:Paint()
    return true
end

function Graph:Pan(dx, dy)
    if move(self, dx, dy) then self:SavePosition() end
end

function Graph:Zoom(delta)
    local zoom = math.max(0.82, math.min(1.35, self.zoom + delta))
    if zoom == self.zoom then return end
    local ratio = zoom / self.zoom
    self.x, self.y = self.x * ratio, self.y * ratio
    self.zoom = zoom
    self:Paint()
    self:SavePosition()
end

function Graph:Fit(reset)
    local width, height = self.frame:GetSize()
    self.zoom = reset and 1 or math.max(0.82, math.min(1, width / self.width, height / self.height))
    self.x, self.y = 0, 0
    local root = self.layout[1]
    if root and self.width * self.zoom > width then
        self.x = self.compactWidth and 0 or width / 2 - (root.x + root.width / 2) * self.zoom
    end
    self:Paint()
    self:SavePosition()
end

function Graph:Toggle(path)
    if not self.collapsed then return end
    self.collapsed[path] = not self.collapsed[path] or nil
    self:Relayout()
    self:Paint()
end

function Graph:Relayout()
    local previousHeight = self.height
    local width = self.frame:GetWidth()
    self.compactWidth = self.compact and math.max(148, math.min(324, width - 28)) or nil
    self.layout, self.width, self.height = Graph.Layout(self.root, self.collapsed or {}, self.compactWidth, self.outputPrices ~= nil)
    if self.onExtentChanged and self.height ~= previousHeight then
        self.notifyingExtent = true
        self.onExtentChanged()
        self.notifyingExtent = nil
    end
end

function Graph:Render(root, position, collapsed, selected, nextTask, job, outputAmount, outputPrices)
    local newView = self.position ~= position
    self.root, self.position, self.collapsed = root, position, collapsed
    self.nextTask = nextTask
    self.job, self.outputAmount, self.outputPrices = job, outputAmount, outputPrices
    self.tasks, self.receipts = {}, {}
    if job then
        for _, task in ipairs(job.tasks or {}) do self.tasks[task.taskId] = task end
        for _, requirement in ipairs(job.requirements or {}) do
            local quantity = requirement.quantity
            if requirement.requirementId and type(quantity) == "number" and quantity > 0 then
                self.receipts[requirement.requirementId] = {requirement = requirement, cardQuantity = 0,
                    received = math.max(0, quantity - (requirement.remaining or quantity))}
            end
        end
        -- The requirement ledger observes receipts without assigning them to cards.
        local function markSharedReceipts(node)
            for _, purchase in ipairs(node.purchases or {}) do
                local receipt = self.receipts[purchase.requirementId]
                if receipt then
                    if receipt.node and receipt.node ~= node then
                        receipt.shared = true
                    else
                        receipt.node = node
                        receipt.cardQuantity = receipt.cardQuantity + (purchase.purchased or purchase.quantity or 0)
                    end
                end
            end
            for _, child in ipairs(node.children or {}) do markSharedReceipts(child) end
        end
        if root then markSharedReceipts(root) end
    end
    self:Relayout()
    local selection = selected and self.layout[1]
    if selection and selection.path ~= selected then
        for index = 2, #self.layout do
            local entry = self.layout[index]
            if entry.path == selected then selection = entry; break end
        end
    end
    self.selected = selection and selection.path
    if newView then
        self.x, self.y, self.zoom = position.x or 0, position.y or 0, position.zoom or 1
    end
    if root and not position.zoom then self:Fit() else self:Paint() end
    return selection
end

local function taskStatus(view, task)
    if task.blocker then return task.blocker end
    if task.status == "pending" then
        local job = view.job
        if job.status ~= "running" and job.status ~= "queued" then return L[job.status] or L.pending end
        if not FC.Queue.CanProcess(job, task) then return L.noReadyCraft end
    end
    return L[task.status]
end

local function showProgress(view, node)
    local total, confirmed = 0, 0
    local states, seenStates, shownReceipts = {}, {}, {}
    for _, craft in ipairs(node.crafts or {}) do
        local task = view.tasks[craft.taskId]
        if task then
            total = total + (task.outputQuantity or craft.outputQuantity or 0)
            confirmed = confirmed + FC.Queue.VisibleCompletedExecutions(task) * (task.yield or craft.yield or 0)
            local status = taskStatus(view, task)
            if status and not seenStates[status] then
                states[#states + 1], seenStates[status] = status, true
            end
        end
    end
    for _, purchase in ipairs(node.purchases or {}) do
        local receipt = view.receipts[purchase.requirementId]
        if receipt and not shownReceipts[receipt] then
            shownReceipts[receipt] = true
            local remaining = FC.Queue.AcquisitionRemaining(view.job, receipt.requirement)
            if receipt.shared or remaining ~= receipt.requirement.quantity - receipt.received then
                local text = receipt.shared and L.nodeSharedReceipt or L.nodeMaterialReceipt
                GameTooltip:AddLine(text:format(receipt.received, remaining), 0.65, 0.88, 0.56)
            else
                total = total + receipt.cardQuantity
                confirmed = confirmed + math.min(receipt.cardQuantity, receipt.received)
            end
        end
    end
    if total > 0 then GameTooltip:AddLine(L.nodeProgress:format(confirmed, total), 0.65, 0.88, 0.56) end
    for _, status in ipairs(states) do GameTooltip:AddLine(status, 0.91, 0.84, 0.71, true) end
end

function Graph:ShowTooltip(card)
    if not self.onTooltip then return end
    local node = card.entry.node
    self.onTooltip(card, node)
    if not GameTooltip or not GameTooltip.IsOwned or not GameTooltip:IsOwned(card) then return end
    if not card.entry.parent and self.outputPrices then GameTooltip:AddLine(self.outputPrices.auction) end
    GameTooltip:AddLine(Graph.SourceLabel(node), 0.91, 0.84, 0.71, true)
    if self.job then showProgress(self, node) end
    if card.nextStep then GameTooltip:AddLine(L.next, 0.65, 0.88, 0.56) end
    GameTooltip:Show()
end

local function segment(view, index, x1, y1, x2, y2, width, height)
    local left, top = math.max(0, math.min(x1, x2)), math.max(0, math.min(y1, y2))
    local right, bottom = math.min(width, math.max(x1, x2) + 1.5), math.min(height, math.max(y1, y2) + 1.5)
    if left >= right or top >= bottom then return index end
    index = index + 1
    local line = view.lines[index]
    if not line then
        line = view.frame:CreateTexture(nil, "ARTWORK")
        color(line, 0.6, 0.43, 0.24, 0.9)
        view.lines[index] = line
    end
    line:ClearAllPoints()
    line:SetPoint("TOPLEFT", view.frame, "TOPLEFT", left, -top)
    line:SetSize(right - left, bottom - top)
    line:Show()
    return index
end

local function paintCard(view, card, entry, x, y, width, height)
    local node = entry.node
    local newEntry = card.entry ~= entry
    if newEntry then
        card.entry = entry
        styleCard(card, not entry.parent)
        local nextStep = false
        for _, craft in ipairs(node.crafts or {}) do
            if craft.taskId and craft.taskId == view.nextTask then nextStep = true; break end
        end
        if node.taskId and node.taskId == view.nextTask then nextStep = true end
        card.nextStep = nextStep
        if nextStep then color(card.edge, 0.53, 0.78, 0.36, 1)
        elseif entry.path == view.selected then color(card.edge, 0.91, 0.67, 0.27, 1)
        else color(card.edge, 0.44, 0.35, 0.24, 1) end
        local count = not entry.parent and view.outputAmount
            or (node.required or 0) > 0 and tostring(node.required) or ""
        card.count:SetText(count)
        card.fold:SetShown(entry.branch)
        card.fold:SetText(view.collapsed[entry.path] and L.expand or L.collapse)
    end
    if card.paintX ~= x or card.paintY ~= y then
        card:ClearAllPoints()
        card:SetPoint("TOPLEFT", view.frame, "TOPLEFT", x, -y)
        card.paintX, card.paintY = x, y
    end
    local resized = card.paintWidth ~= width or card.paintHeight ~= height
    if resized then
        card:SetSize(width, height)
        card.paintWidth, card.paintHeight = width, height
    end
    -- Item data can become available while scrolling through the existing plan.
    local name, icon = view.itemInfo(node.itemID)
    local renamed = card.itemName ~= name
    if renamed then
        card.name:SetText(name)
        card.itemName = name
    end
    if card.itemIcon ~= icon then
        card.icon:SetTexture(icon)
        card.itemIcon = icon
    end
    if newEntry or resized or renamed then placeCaption(card, width, entry.branch, L[node.source] or "", node, view.outputPrices) end
    card:Show()
end

function Graph:Paint()
    local width, height = self.frame:GetSize()
    if not width or width < 1 or not height or height < 1 then return end
    local index, lineIndex, zoom = 0, 0, self.zoom
    self.x, self.y = Graph.ClampPan(width, height, self.width, self.height, zoom, self.x, self.y)
    local ox = self.x + (self.compactWidth and 0 or math.max(0, (width - self.width * zoom) / 2))
    local partial = self.frame.SetClipsChildren ~= nil
    for _, entry in ipairs(self.layout) do
        local cardWidth, cardHeight = entry.width * zoom, entry.height * zoom
        local x, y = ox + entry.x * zoom, self.y + entry.y * zoom
        if entry.parent and self.compactWidth then
            local rail = ox + (entry.parent.x + 8) * zoom
            local start = self.y + (entry.parent.y + entry.parent.height) * zoom
            local finish = y + cardHeight / 2
            lineIndex = segment(self, lineIndex, rail, start, rail, finish, width, height)
            lineIndex = segment(self, lineIndex, rail, finish, x, finish, width, height)
        elseif entry.parent then
            local px = ox + (entry.parent.x + entry.parent.width / 2) * zoom
            local py = self.y + (entry.parent.y + entry.parent.height) * zoom
            local center, bend = x + cardWidth / 2, (py + y) / 2
            lineIndex = segment(self, lineIndex, px, py, px, bend, width, height)
            lineIndex = segment(self, lineIndex, px, bend, center, bend, width, height)
            lineIndex = segment(self, lineIndex, center, bend, center, y, width, height)
        end
        local visible = partial and x + cardWidth > 0 and y + cardHeight > 0 and x < width and y < height
            or not partial and x >= 0 and y >= 0 and x + cardWidth <= width and y + cardHeight <= height
        if visible then
            index = index + 1
            local card = self.cards[index] or makeCard(self)
            self.cards[index] = card
            paintCard(self, card, entry, x, y, cardWidth, cardHeight)
        end
    end
    for i = index + 1, #self.cards do self.cards[i]:Hide() end
    for i = lineIndex + 1, #self.lines do self.lines[i]:Hide() end
end

function Graph.New(parent, itemInfo, onSelect, onTooltip)
    local view = setmetatable({cards = {}, lines = {}, layout = {}, width = 1, height = 1,
        position = {}, x = 0, y = 0, zoom = 1, itemInfo = itemInfo,
        onSelect = onSelect, onTooltip = onTooltip}, {__index = Graph})
    local frame = CreateFrame("Frame", nil, parent)
    view.frame = frame
    local fill = frame:CreateTexture(nil, "BACKGROUND")
    fill:SetAllPoints()
    color(fill, 0.055, 0.047, 0.041, 1)
    local atlas = "Professions-background-summarylist"
    if FC.target == "forever" and C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(atlas) then
        local artwork = frame:CreateTexture(nil, "BACKGROUND", nil, 1)
        artwork:SetAllPoints()
        artwork:SetAtlas(atlas)
        artwork:SetAlpha(0.45)
    end
    if frame.SetClipsChildren then frame:SetClipsChildren(true) end
    frame:EnableMouse(true)
    frame:EnableMouseWheel(true)
    frame:SetScript("OnSizeChanged", function()
        -- The queue can resize the viewport height for a new extent. The caller
        -- already has the updated layout and will paint at the new height.
        if view.notifyingExtent then return end
        view:Relayout()
        view:Paint()
    end)
    frame:SetScript("OnMouseWheel", function(_, delta) view:Scroll(delta) end)
    frame:SetScript("OnMouseDown", function(self, mouse)
        if mouse ~= "LeftButton" or not GetCursorPosition then return end
        local x, y = GetCursorPosition()
        self:SetScript("OnUpdate", function()
            if IsMouseButtonDown and not IsMouseButtonDown("LeftButton") then
                self:SetScript("OnUpdate", nil)
                view:SavePosition()
                return
            end
            local nx, ny = GetCursorPosition()
            if nx == x and ny == y then return end
            local scale = self:GetEffectiveScale()
            move(view, (nx - x) / scale, (y - ny) / scale)
            x, y = nx, ny
        end)
    end)
    frame:SetScript("OnMouseUp", function(self)
        self:SetScript("OnUpdate", nil)
        view:SavePosition()
    end)
    return view
end
