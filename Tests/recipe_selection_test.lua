-- Native selection state changes immediately while expensive preview work
-- waits until the selected recipe has settled.
local function setup()
    local addon, flush, stock, events = dofile("Tests/ui_fixture.lua")("forever")
    local work, page = addon.UI, ProfessionsFrame.CraftingPage
    local catalog = addon.Catalog.Snapshot()
    catalog.recipesById[33].constraints = nil
    stock[300] = 8
    catalog.revision = catalog.revision + 1
    work.Refresh()
    flush()

    local function selectNative(id)
        page.SchematicForm.selectedID = id
        events["Professions.RecipeSelected"](page)
    end

    local planned, preview = {}, addon.Logistics.Preview
    addon.Logistics.Preview = function(args, ...)
        planned[#planned + 1] = args.recipeId
        return preview(args, ...)
    end
    return addon, work, page, flush, selectNative, planned, stock, events
end

local function useFrameClock()
    local now, timers = 0, {}
    C_Timer.After = function(delay, callback)
        timers[#timers + 1] = {at = now + (delay == 0 and 16 or delay * 1000), callback = callback}
    end
    return function(milliseconds)
        local untilTime = now + milliseconds
        while true do
            local nextTimer
            for index, timer in ipairs(timers) do
                if timer.at <= untilTime and (not nextTimer or timer.at < timers[nextTimer].at) then
                    nextTimer = index
                end
            end
            if not nextTimer then break end
            local timer = table.remove(timers, nextTimer)
            now = timer.at
            timer.callback()
        end
        now = untilTime
    end
end

do
    local _, work, _, flush, selectNative, planned = setup()
    assert(work.preview.rootRecipeId == 11)
    selectNative(33)
    assert(work.selectedRecipeId == 33 and work.preview == nil and work.context == nil and #planned == 0,
        "native selection must expose the new identity immediately and clear the stale plan")
    selectNative(11)
    selectNative(33)
    assert(work.selectedRecipeId == 33 and #planned == 0, "rapid native selection cannot run the planner inline")
    flush()
    assert(#planned == 1 and planned[1] == 33 and work.preview.rootRecipeId == 33,
        "rapid native selection must plan the latest choice once")

    selectNative(33)
    selectNative(33)
    flush()
    assert(#planned == 1 and work.preview.rootRecipeId == 33,
        "duplicate native selection while browsing cannot rebuild an unchanged draft")
end

do
    local addon, work, page, flush, selectNative, planned = setup()
    local catalog = addon.Catalog.Snapshot()
    catalog.recipesById[11].reagents = {{itemID = 110, quantity = 1}}
    catalog.revision = catalog.revision + 1
    work.Refresh()
    flush()
    local before = #planned
    local producer
    for _, card in ipairs(work.graph.cards) do
        if card:IsVisible() and card.entry and card.entry.node.itemID == 110 then producer = card; break end
    end
    assert(producer, "the Flowcraft fixture must expose its same-profession producer")
    local nativeRow = {GetData = function() return {recipeInfo = {recipeID = 33, learned = true}} end}
    page.RecipeList.ScrollBox = {FindElementDataByPredicate = function(_, predicate)
        return predicate(nativeRow) and nativeRow or nil
    end}
    local nativeSelects = 0
    function page:SelectRecipe(info)
        nativeSelects = nativeSelects + 1
        selectNative(info.recipeID)
    end
    producer:Fire("OnClick", "LeftButton")
    local navigate
    for _, control in ipairs(work.menu.actions) do
        if control:IsVisible() and control:GetText() == addon.L.navigate then navigate = control; break end
    end
    assert(navigate, "the Flowcraft card must expose its native recipe action")
    navigate:Fire("OnClick")
    assert(nativeSelects == 1 and work.selectedRecipeId == 33 and work.preview == nil
        and #planned == before, "the synchronous Blizzard selection echo must not run planning")
    flush()
    assert(#planned == before + 1 and planned[#planned] == 33 and work.preview.rootRecipeId == 33,
        "Flowcraft browsing and its native echo must share one deferred plan")
end

do
    local addon, work, _, flush, selectNative, planned = setup()
    assert(work.preview.rootRecipeId == 11 and #addon.Queue.GetJobs() == 0)
    selectNative(33)
    work.queuePlan:Fire("OnClick")
    local job = assert(addon.Queue.GetJobs()[1], "Queue must refresh the newest selection at the time of the click")
    assert(job == work.job and job.rootRecipeId == 33 and #addon.Queue.GetJobs() == 1
        and #planned > 0 and planned[#planned] == 33, "the prior recipe cannot be queued by a fast click")
    for _, recipeID in ipairs(planned) do assert(recipeID == 33, "fast Queue planned an obsolete recipe") end
    flush()
    assert(work.job == job and #addon.Queue.GetJobs() == 1, "the deferred selection must not replace or submit the accepted job")

    selectNative(33)
    assert(work.selectedRecipeId == 33 and work.job == nil and job.status == "queued",
        "explicit native browsing of the same recipe must leave the accepted job intact while clearing its inspection")
    flush()
    assert(work.preview.rootRecipeId == 33 and addon.Queue.GetJob(job.id) == job)
end

do
    local addon, work, _, _, selectNative, _, stock, events = setup()
    local advance = useFrameClock()
    local revision = 1
    addon.InventoryAdapter.GetRevision = function() return "test-bags:" .. revision end
    local started, completed, preview = {}, {}, addon.Logistics.Preview
    addon.Logistics.Preview = function(args, ...)
        local pause = args.pauseSearch
        if not pause then return preview(args, ...) end
        started[#started + 1] = args.recipeId
        args.pauseSearch = nil
        local plan, context = preview(args, ...)
        args.pauseSearch = pause
        pause()
        pause()
        completed[#completed + 1] = args.recipeId
        return plan, context
    end

    selectNative(33)
    advance(16)
    local worker = assert(work.pendingDraft)
    assert(work.selectedRecipeId == 33 and work.status:GetText() == addon.L.calculatingPlan)
    stock[300], revision = 7, 2
    local function emitBagUpdate()
        addon:Emit("INVENTORY_CHANGED", addon.InventoryAdapter.GetStatus(), {regions = {bags = true}})
    end
    emitBagUpdate()
    advance(16)
    events.GET_ITEM_INFO_RECEIVED:Fire("OnEvent", "GET_ITEM_INFO_RECEIVED", 999999, true)
    emitBagUpdate()
    assert(work.pendingDraft == worker and worker.id == 33 and worker.worker and worker.refresh
        and #started == 1 and #completed == 0,
        "same-selection background notifications must let the cold search advance")
    advance(16)
    local displayed = assert(work.preview, "the first search must still publish during background activity")
    assert(#completed == 1 and displayed.rootRecipeId == 33 and work.context.inventory[300] == 8)

    for _ = 1, 20 do
        if #started == 2 then break end
        advance(16)
    end
    assert(#started == 2 and #completed == 1 and work.pendingDraft and work.preview == displayed
        and work.graph.root == displayed.tree and not work.queuePlan.enabled,
        "the queued refresh must keep the first graph visible until the fresh estimate can be accepted")
    advance(48)
    assert(#completed == 2 and not work.pendingDraft and work.preview ~= displayed
        and work.preview.rootRecipeId == 33 and work.context.inventory[300] == 7 and work.queuePlan.enabled,
        "the one follow-up must settle with the updated bag snapshot")

    selectNative(11)
    advance(16)
    local obsolete = assert(work.pendingDraft)
    assert(obsolete.id == 11 and #started == 3)
    selectNative(33)
    advance(80)
    assert(#started == 4 and #completed == 3 and completed[3] == 33 and work.preview.rootRecipeId == 33
        and not work.pendingDraft, "explicit recipe selection must still retire the previous worker")
end

do
    local addon, work, _, _, selectNative = setup()
    local advance = useFrameClock()
    local asynchronous, synchronous, preview = 0, 0, addon.Logistics.Preview
    addon.Logistics.Preview = function(args, ...)
        if args.pauseSearch then
            asynchronous = asynchronous + 1
            args.pauseSearch()
            error("fixture interrupted the deferred search")
        end
        synchronous = synchronous + 1
        return preview(args, ...)
    end
    selectNative(33)
    advance(64)
    assert(asynchronous == 1 and synchronous == 1 and not work.pendingDraft and not work.recipeSelectionPending
        and work.preview.rootRecipeId == 33 and work.status:GetText() ~= addon.L.calculatingPlan,
        "a failed deferred search must retry once synchronously and leave the calculating state")
end

do
    local addon, work, _, _, selectNative = setup()
    local advance = useFrameClock()
    local preview = addon.Logistics.Preview
    local previousHandler, reported = geterrorhandler, false
    geterrorhandler = function() return function() reported = true end end
    addon.Logistics.Preview = function() error("fixture provider unavailable") end
    selectNative(33)
    advance(16)
    geterrorhandler = previousHandler
    assert(reported and not work.preview and not work.pendingDraft and work.status:GetText() == addon.L.previewFailed,
        "errors in both planning paths must leave the visible plan in a retryable state")
    addon.Logistics.Preview = preview
    selectNative(33)
    advance(16)
    assert(work.preview and work.preview.rootRecipeId == 33 and work.graph.root == work.preview.tree,
        "clicking the same native recipe after a failure must retry the preview")
end

print("Recipe selection coalesces native events without delaying exact queue intent")
