local setup = dofile("Tests/ui_fixture.lua")
local cursorX, cursorY = 0, 0
local down, combat, gamepad = false, false, false
GetCursorPosition = function() return cursorX, cursorY end
IsMouseButtonDown = function(button) return button == "LeftButton" and down end
InCombatLockdown = function() return combat end
InputUtil = {IsGamepadUIEnabled = function() return gamepad end}

local function begin(grip)
    cursorX, cursorY, down = 500, 500, true
    grip:Fire("OnMouseDown", "LeftButton")
end

local function move(grip, dx, dy)
    cursorX, cursorY = 500 + dx, 500 - dy
    grip:Fire("OnUpdate")
end

local function release(grip)
    down = false
    grip:Fire("OnMouseUp", "LeftButton")
end

local function size(frame, width, height)
    local actualWidth, actualHeight = frame:GetSize()
    assert(actualWidth == width and actualHeight == height,
        string.format("expected %d × %d, got %d × %d", width, height, actualWidth, actualHeight))
end

local backdrop, nativeCreateAll, flushedBackdropLayout
local ns, flush, _, events = setup("forever", nil, function()
    local page = ProfessionsFrame.CraftingPage
    backdrop = page:CreateTexture()
    backdrop:SetSize(667, 570)
    backdrop.GetAtlas = function() return "Profession-Background-Template2" end
    local backdropReady, getBackdropSize = false, backdrop.GetSize
    backdrop.GetSize = function(self)
        if backdropReady then return getBackdropSize(self) end
        if not flushedBackdropLayout then
            flushedBackdropLayout = true
            page:Fire("OnSizeChanged", page:GetSize())
        end
        return nil, nil
    end
    C_Timer.After(0, function() backdropReady = true end)
    page.GetRegions = function() return backdrop end
    page.DoesClipChildren = function(self) return self.clips or false end

    nativeCreateAll = CreateFrame("Button", nil, page)
    nativeCreateAll:SetAlpha(0.85)
    nativeCreateAll.click, nativeCreateAll.motion = true, false
    nativeCreateAll.IsMouseClickEnabled = function(self) return self.click end
    nativeCreateAll.IsMouseMotionEnabled = function(self) return self.motion end
    nativeCreateAll.SetMouseClickEnabled = function(self, enabled) self.click = enabled end
    nativeCreateAll.SetMouseMotionEnabled = function(self, enabled) self.motion = enabled end
    page.CreateAllButton = nativeCreateAll
end)
local ui, host = ns.UI, ProfessionsFrame
local page, grip = host.CraftingPage, ui.resizeGrip
assert(flushedBackdropLayout and ui.window:IsVisible() and ui.coveredNativeSurface.art == backdrop,
    "opening the workbench survives nested native layout and captures the backdrop once its size is available")
local nativeWidth, nativeHeight = host:GetSize()
host.left, host.top, host.currentPageWidth = 22, 860, nativeWidth
host:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 22, -40)
local nativeAnchor = host.points.TOPLEFT
local panelUpdates = 0
UpdateUIPanelPositions = function(frame)
    assert(frame == host and frame.points.TOPLEFT == nativeAnchor)
    panelUpdates = panelUpdates + 1
end
-- The fixture has independent frame sizes. Mirror the anchor-driven native and graph viewports.
host:HookScript("OnSizeChanged", function(_, width, height)
    page:SetSize(width, height)
    ui.window:SetSize(width - 319, height - 77)
    ui.plan:SetSize(width - 336, height - 149)
    ui.graph.frame:SetWidth(width - 336)
end)
local selection, graphView = ui.selectedRecipeId, ui.graph.position
ui.graph:Zoom(0.12)
local zoom = graphView.zoom
assert(grip:IsVisible() and not ui.saved.workbenchSize)
begin(grip)
move(grip, 210, 105)
size(host, nativeWidth + 210, nativeHeight + 105)
assert(not ui.saved.workbenchSize and ui.graph.frame:GetWidth() == nativeWidth + 210 - 336)
release(grip)
assert(ui.saved.workbenchSize.width == nativeWidth + 210 and ui.saved.workbenchSize.height == nativeHeight + 105)
assert(panelUpdates == 1 and ui.selectedRecipeId == selection and ui.graph.position == graphView and graphView.zoom == zoom)
assert(host.currentPageWidth == nativeWidth and host.points.TOPLEFT == nativeAnchor)

host.currentPageWidth = 770
host:SetWidth(770)
flush()
size(host, nativeWidth + 210, nativeHeight + 105)
page:Hide()
host.BookPage:Show()
size(host, 770, nativeHeight)
assert(not grip:IsVisible() and host.currentPageWidth == 770)
assert(not page:DoesClipChildren() and nativeCreateAll:GetAlpha() == 0.85 and nativeCreateAll.click
    and not nativeCreateAll.motion, "the native page regains its previous artwork and interaction state")
host.BookPage:Hide()
page:Show()
size(host, nativeWidth + 210, nativeHeight + 105)
ui.ShowNative()
size(host, 770, nativeHeight)
assert(not grip:IsVisible() and ui.returnButton:IsVisible())
assert(page.SchematicForm:GetAlpha() == 1 and page.CreateButton:GetAlpha() == 1)
ui.ShowWorkbench(true)
size(host, nativeWidth + 210, nativeHeight + 105)

gamepad = true
events.INPUT_DEVICE_INTERFACE_TRANSITION:Fire("OnEvent", "INPUT_DEVICE_INTERFACE_TRANSITION")
size(host, 770, nativeHeight)
assert(not grip:IsVisible() and not ui.returnButton:IsVisible())
assert(page.SchematicForm:GetAlpha() == 1 and nativeCreateAll.click)
gamepad = false
events.INPUT_DEVICE_INTERFACE_TRANSITION:Fire("OnEvent", "INPUT_DEVICE_INTERFACE_TRANSITION")
size(host, nativeWidth + 210, nativeHeight + 105)

combat = true
begin(grip)
move(grip, 80, 60)
release(grip)
size(host, nativeWidth + 210, nativeHeight + 105)
ui.ShowNative()
combat = false
events.PLAYER_REGEN_ENABLED:Fire("OnEvent", "PLAYER_REGEN_ENABLED")
size(host, 770, nativeHeight)
ui.ShowWorkbench(true)

begin(grip)
move(grip, -2000, -2000)
release(grip)
size(host, 640, 462)
size(backdrop, 637, 441)
assert(not page:DoesClipChildren() and nativeCreateAll:IsShown() and nativeCreateAll:GetAlpha() == 0
    and not nativeCreateAll.click and not nativeCreateAll.motion,
    "the resized page leaves the native recipe list's clipping alone and the hidden Create All cannot intercept its rows")
ui.queuePlan:Fire("OnClick")
local row = assert(ui.queueRows[1])
assert(row.line and row:GetHeight() == 34 and row.progress.points.TOPLEFT[2] == -17
    and ui.graph.frame:GetHeight() + row:GetHeight() + 128 <= ui.plan:GetHeight(),
    "the queue keeps a second line for the current step within the compact viewport")

ns.AuctionatorAdapter = {CanSearchList = function() return true end, IsAvailable = function() return false end}
FluxAuctionRestock = {ScanLogisticsBooks = function() end}
AuctionHouseFrame = CreateFrame("Frame", nil, UIParent)
events.AUCTION_HOUSE_SHOW:Fire("OnEvent", "AUCTION_HOUSE_SHOW")
assert(ui.recipeAuctionator:IsShown() and ui.auctionPriceButton:IsShown()
    and ui.recipeAuctionator.points.TOPLEFT[2] == -22 and ui.plan.points.TOPLEFT[2] == -47,
    "both AH tools get a separate toolbar row when they would overlap the zoom controls")
ns.AuctionatorAdapter.CanSearchList = function() return false end
events.AUCTION_HOUSE_SHOW:Fire("OnEvent", "AUCTION_HOUSE_SHOW")
assert(not ui.recipeAuctionator:IsShown() and ui.auctionPriceButton.points.TOPLEFT[2] == 0
    and ui.plan.points.TOPLEFT[2] == -25, "Check prices uses the top-left space when it is the only auction tool")
AuctionHouseFrame:Hide()
events.AUCTION_HOUSE_CLOSED:Fire("OnEvent", "AUCTION_HOUSE_CLOSED")
assert(ui.plan.points.TOPLEFT[2] == -25)
AuctionHouseFrame, FluxAuctionRestock = nil, nil

ui.ShowNative()
size(backdrop, 667, 570)
assert(not page:DoesClipChildren() and nativeCreateAll:GetAlpha() == 0.85 and nativeCreateAll.click)
ui.ShowWorkbench(true)
size(host, 640, 462)
size(backdrop, 637, 441)
begin(grip)
move(grip, 3000, 3000)
release(grip)
size(host, 1534, 852)
assert(row:GetHeight() == 20 and row.progress.points.TOPRIGHT[2] == -3)
local savedSize = ui.saved.workbenchSize
host:Hide()
size(host, 770, nativeHeight)
assert(not grip:IsVisible())
host:Show()
size(host, savedSize.width, savedSize.height)

UpdateUIPanelPositions = nil
local restarted = setup("forever", ui.saved)
size(ProfessionsFrame, savedSize.width, savedSize.height)
restarted.UI.ShowNative()
size(ProfessionsFrame, nativeWidth, nativeHeight)

local classic = setup("classic", nil, function(ns)
    local list = ns.Clients.ListProfessions()
    for index = 3, 8 do
        list[index] = {id = 100 + index, name = "Trade skill " .. index, texture = 200 + index}
    end
    ns.Clients.ListProfessions = function() return list end
end)
local classicUI = classic.UI
local shell, trade = classicUI.classic, TradeSkillFrame
local oldWidth, oldHeight = shell:GetSize()
local tradeWidth, tradeHeight = trade:GetSize()
-- The mock widgets do not derive geometry from both anchors automatically.
classicUI.window.GetSize = function() return shell:GetWidth() - 11, shell:GetHeight() - 83 end
classicUI.Layout()
local oldListWidth = classicUI.listPane:GetWidth()
assert(classicUI.resizeGrip:IsVisible() and classicUI.graph.compact)
local rail, tabs = classicUI.professionRail, classicUI.professionTabs
assert(rail.parent == shell and rail.points.TOPRIGHT and classicUI.overviewTab:IsVisible(),
    "the profession and overview tabs must attach at the right edge")
assert(#tabs >= 8 and tabs[1]:GetChecked() and tabs[8]:IsVisible(),
    "every learned profession has a tab beyond the former six-slot limit")
local firstTabWidth = tabs[1]:GetWidth()
begin(classicUI.resizeGrip)
move(classicUI.resizeGrip, 75, 40)
release(classicUI.resizeGrip)
size(shell, oldWidth + 75, oldHeight + 40)
size(trade, tradeWidth, tradeHeight)
local secondTabAnchor = tabs[2].points.TOP or tabs[2].points.TOPLEFT or tabs[2].points.TOPRIGHT
assert(tabs[1]:GetWidth() == firstTabWidth and rail.points.TOPRIGHT and tabs[8]:IsVisible()
    and secondTabAnchor and secondTabAnchor[1] == tabs[1],
    "the icon tabs must keep their width and vertical order as the shell widens")
assert(classicUI.listPane:GetWidth() > oldListWidth and classicUI.listPane:GetWidth() <= 320,
    "the compact recipe list should grow within its bound as the shell widens")
local classicSaved = classicUI.saved.workbenchSize
classicUI.ShowNative()
assert(not classicUI.resizeGrip:IsVisible() and not rail:IsVisible() and trade:GetAlpha() == 1 and classicUI.returnButton:IsVisible())
classicUI.returnButton:Fire("OnClick")
size(shell, classicSaved.width, classicSaved.height)
assert(rail:IsVisible() and tabs[1]:GetChecked())
local classicReload = setup("classic", classicUI.saved)
size(classicReload.UI.classic, classicSaved.width, classicSaved.height)

print("Forever native panel and Classic workbench resize fixtures passed")
