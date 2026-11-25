local eventFrame
function CreateFrame()
    eventFrame = {RegisterEvent = function() end, SetScript = function(self, _, fn) self.onEvent = fn end}
    return eventFrame
end

local now, timers = 0, {}
local function schedule(seconds, fn)
    local timer = {at = now + seconds, run = fn, Cancel = function(self) self.cancelled = true end}
    timers[#timers + 1] = timer
    return timer
end
C_Timer = {After = schedule, NewTimer = schedule}
C_TradeSkillUI = {GetRemainingRecasts = function() return 0 end}
local function advance(seconds)
    now = now + seconds
    repeat
        local index
        for i, timer in ipairs(timers) do
            if timer.at <= now and (not index or timer.at < timers[index].at) then index = i end
        end
        if not index then return end
        local timer = table.remove(timers, index)
        if not timer.cancelled then timer.run() end
    until false
end
local function event(name, ...)
    eventFrame.onEvent(eventFrame, name, ...)
end

local FC = {target = "forever", version = "0.2.32-fixture",
    state = {characterKey = "actor-A", build = 16001, clientBuild = 71037}}
function FC:Emit() end
function FC:On() end
local function loadModule(module)
    assert(loadfile("FluxCraft/" .. module .. ".lua"))("FluxLogistics", FC)
end
loadModule("Locale")
loadModule("Planner")
loadModule("Queue")
local saved = {}
assert(FC.Queue.Initialize(saved))

local function accept(id, profession, executions, stamp)
    local outputID = 1000 + id
    local plan = {status = "ready", revision = stamp, rootRecipeId = id, rootItemID = outputID,
        tree = {itemID = outputID, required = executions * 2, source = "Make", children = {}},
        tasks = {{taskId = "t1", recipeId = id, professionId = profession,
            outputItemID = outputID, outputKind = "item", yield = 2, outputQuantity = executions * 2,
            executions = executions, recipeRevision = 1, dependencies = {}, inputs = {}}},
        requirements = {}, summary = {output = executions * 2}}
    return assert(FC.Queue.Accept(plan, function() return plan end))
end

local craftCalls, switches, proposedBatch, nativeLimit = 0, 0
local open, sourceCounter = 171, 1
local output, recipes = {}, {}
local mode = "complete"
FC.InventoryAdapter = {
    GetStatus = function() return {reliable = true} end,
    Count = function(id) return output[id] or 0 end,
    GetRevision = function() return "bags:1" end,
    Snapshot = function(items)
        local result = {}
        for _, id in ipairs(items) do result[id] = output[id] or 0 end
        return result
    end,
}
FC.Catalog = {
    Refresh = function() end,
    Snapshot = function() return {recipesById = recipes} end,
}
local function recipe(id, profession)
    local row = {id = id, recipeID = id, professionId = profession,
        outputItemID = 1000 + id, outputKind = "item", yield = 2, learned = true, revision = 1}
    recipes[id] = row
    return row
end
local watchedTask
FC.Clients = {
    CurrentProfessionID = function() return open, sourceCounter end,
    SwitchProfession = function(id)
        assert(id == 197)
        switches = switches + 1
        return true
    end,
    Resolve = function(task)
        if mode == "legacy" then return {kind = "classic", index = 1, maxYield = 2} end
        return {kind = "forever", recipeID = task.recipeId, maxYield = mode == "variable" and 3 or 2}
    end,
    Craft = function(task, _, batch, beforeClick)
        craftCalls = craftCalls + 1
        watchedTask = task
        proposedBatch = batch
        if mode == "disabled" then return false, "native output bags are full" end
        if mode == "changed-stock" then
            output[9001] = 0
            assert(not beforeClick(batch), "carried stock changed after craft preparation")
            return false, "queue intent was rejected"
        end
        if mode == "changed-session" then
            sourceCounter = sourceCounter + 1
            assert(not beforeClick(batch), "same-profession source changed after preparation")
            return false, "queue intent was rejected"
        end
        if nativeLimit then batch = math.min(batch, nativeLimit) end
        assert(beforeClick(batch), "intent was not persisted before native click")
        if task.status ~= "in_flight" then
            local newest = FC.Queue.GetJobs()[#FC.Queue.GetJobs()]
            assert(newest.goal.directCraft and newest.tasks[1].recipeId == task.recipeId
                and newest.tasks[1].executions >= batch and newest.tasks[1].status == "in_flight")
            assert(#newest.requirements == 0 and not newest.goal.autoBuyVendor)
            task, watchedTask = newest.tasks[1], newest.tasks[1]
        end
        if mode == "unsubmitted" then return false, "native form changed", "not_submitted" end
        if mode == "click-error" then error("native handler raised after an attempted click") end
        if mode == "legacy" then
            output[task.outputItemID] = 2
            event("UNIT_SPELLCAST_SUCCEEDED", "party1", "foreign-guid", task.recipeId)
            event("UNIT_SPELLCAST_SUCCEEDED", "player", "unrelated-guid", 999)
            assert(task.status == "in_flight", "unrelated Classic spell credited the output")
            event("UNIT_SPELLCAST_SUCCEEDED", "player", "legacy-cast-guid", task.recipeId)
            return true, nil, batch
        end
        if mode == "complete" then
            event("TRADE_SKILL_CRAFT_BEGIN", 999)
            event("TRADE_SKILL_ITEM_CRAFTED_RESULT", {itemID = task.outputItemID, quantity = 2, operationID = 98})
            assert(not task.evidence.sawCraftEvent, "a same-item result without the exact craft begin was misattributed")
        end
        event("TRADE_SKILL_CRAFT_BEGIN", task.recipeId)
        if mode ~= "no-cast" then
            event("UNIT_SPELLCAST_SUCCEEDED", "player", "cast-spell-guid-" .. craftCalls, task.recipeId)
        end
        assert(not task.evidence.sawCraftEvent, "Forever credited both a spell and an output result")
        if mode == "complete" or mode == "partial" or mode == "variable" then
            local previous = task.completedExecutions or 0
            local completed = mode == "complete" and batch or 1
            local actual = mode == "variable" and 3 or 2 * completed
            local result = {itemID = task.outputItemID, quantity = actual, operationID = 99}
            event("TRADE_SKILL_ITEM_CRAFTED_RESULT", result)
            event("TRADE_SKILL_ITEM_CRAFTED_RESULT", result)
            assert(task.evidence.matchedExecutions == completed, "duplicate operation was credited twice")
            assert(FC.Queue.VisibleCompletedExecutions(task) == previous + completed and task.completedExecutions == previous,
                "the native result updates the visible count before the carried snapshot settles")
            output[task.outputItemID] = (output[task.outputItemID] or 0) + actual
            event("BAG_UPDATE_DELAYED")
        end
        return true, nil, batch
    end,
}
loadModule("Execution")

do
    local oldCraft, oldResolve, oldEmit = FC.Clients.Craft, FC.Clients.Resolve, FC.Emit
    local bolt = recipe(3865, 171)
    bolt.outputItemID, bolt.yield = 4339, 1
    local input, outputID = 4338, bolt.outputItemID
    local count, transaction, settlements
    local oldTrade = C_TradeSkillUI
    C_TradeSkillUI = {GetRemainingRecasts = function() return count end}
    local plan = {status = "ready", revision = "native-stock-25", rootRecipeId = bolt.id, rootItemID = outputID,
        tree = {itemID = outputID, required = 25, source = "Make", children = {}}, requirements = {},
        tasks = {{taskId = "bolt", recipeId = bolt.id, professionId = bolt.professionId, outputItemID = outputID,
            outputKind = "item", yield = 1, outputQuantity = 25, executions = 25, recipeRevision = 1,
            dependencies = {}, inputs = {{itemID = input, quantity = 125}}}}, summary = {output = 25}}
    FC.Clients.Resolve = function(task)
        return {kind = "forever", recipeID = task.recipeId, maxYield = 1,
            choice = {{itemID = input, quantity = 5}}}
    end
    FC.Clients.ReadNativeCraftRecasts = function(recipeID)
        assert(recipeID == bolt.id)
        return count, transaction
    end
    function FC:Emit(signal)
        if signal == "NATIVE_CRAFT_SETTLED" then settlements = settlements + 1 end
    end
    local function start()
        assert(FC.Queue.Initialize({}))
        local entry, physicalPress
        FC.Clients.Craft = function(task, _, batch, attempt, nativeEntry)
            assert(task.recipeId == bolt.id and batch == 25)
            entry, physicalPress = nativeEntry, attempt
            return true, nil, "native_click", batch
        end
        count, transaction, settlements = 0, {}, 0
        output[input], output[outputID] = 125, 0
        local queued = assert(FC.Queue.Accept(plan, function() return plan end))
        assert(FC.Execution.ProcessNext(queued))
        entry()
        count = 24 -- The stock Create action has now started the first operation.
        assert(physicalPress(25) and queued.status == "running")
        return queued, queued.tasks[1]
    end
    local function carried(completed, recasts, spent)
        output[input], output[outputID], count = 125 - (spent or (completed * 5)), completed, recasts
        event("BAG_UPDATE_DELAYED")
    end

    local order, task = start()
    for completed = 5, 20, 5 do
        advance(20)
        carried(completed, 24 - completed)
        event("UPDATE_TRADESKILL_CAST_STOPPED", false)
        assert(order.status == "running" and not task.evidence.matchedExecutions and settlements == 0,
            "native recasts keep the exact batch active between carried observations")
    end
    advance(20)
    carried(25, 0)
    assert(order.status == "complete" and task.completedExecutions == 25
        and task.evidence.confirmedByNativeStock == 25 and settlements == 0,
        "the native recasts and exact material/output balances settle all 25 with no craft-result event")

    order, task = start()
    advance(20)
    carried(6, 18)
    advance(20)
    carried(12, 0)
    event("UPDATE_TRADESKILL_CAST_STOPPED", false)
    advance(0)
    assert(order.status == "queued" and task.completedExecutions == 12 and task.remainingExecutions == 13
        and task.evidence.confirmedByNativeStock == 12 and settlements == 0,
        "stopped native recasts credit only the proved 12 bolts and leave 13 pending for a fresh press")

    for _, mismatch in ipairs({"materials", "transaction", "foreign begin"}) do
        order, task = start()
        carried(6, 18)
        if mismatch == "transaction" then transaction = {} end
        if mismatch == "foreign begin" then
            event("TRADE_SKILL_CRAFT_BEGIN", bolt.id)
            event("TRADE_SKILL_CRAFT_BEGIN", 9000)
        end
        carried(12, 0, mismatch == "materials" and 55 or nil)
        event("UPDATE_TRADESKILL_CAST_STOPPED", false)
        advance(180)
        assert(task.completedExecutions == 0 and settlements == 0,
            "time alone cannot credit a mismatched input balance, native transaction or recipe")
        event("TRADE_SKILL_CLOSE")
        assert(order.status == "uncertain" and task.completedExecutions == 0 and settlements == 0,
            "closing the native source invalidates an unresolved mismatched receipt")
    end
    FC.Clients.ReadNativeCraftRecasts = nil
    FC.Clients.Craft, FC.Clients.Resolve, FC.Emit = oldCraft, oldResolve, oldEmit
    C_TradeSkillUI = oldTrade
    assert(FC.Queue.Initialize(saved))
end

local job = accept(222, 171, 1, "observed:1")
local catalogRecipe = recipe(222, 171)
job.characterKey = "other-actor"
FC.Execution.ProcessNext()
assert(craftCalls == 0, "wrong character crafted")
job.characterKey = "actor-A"
catalogRecipe.revision = 2
FC.Execution.ProcessNext()
assert(craftCalls == 0, "stale recipe revision crafted")
assert(not FC.Execution.GetReadyRestockCraft(job), "a stale recipe cannot appear on the Restock button")
catalogRecipe.revision = 1
do
    local restockTask, restockBatch, restockJob = FC.Execution.GetReadyRestockCraft()
    assert(restockTask == job.tasks[1] and restockBatch == 1 and restockJob == job and craftCalls == 0,
        "the ready queue query publishes an exact job and task without submitting it")
    job.acquisition = {status = "issued"}
    assert(not FC.Execution.GetReadyRestockCraft(), "an issued acquisition defers the craft reminder")
    job.acquisition = nil
    assert(FC.Queue.SetPaused(job.id, true))
    assert(not FC.Execution.GetReadyRestockCraft(), "a paused queue job cannot activate the craft reminder")
    assert(FC.Queue.SetPaused(job.id, false))
end
FC.Execution.ProcessNext()
assert(craftCalls == 1 and job.status == "complete", "synchronous native result was lost")

local nextJob = accept(333, 197, 2, "observed:2")
recipe(333, 197)
mode = "partial"
FC.Execution.ProcessTask(nextJob, nextJob.tasks[1])
assert(switches == 1 and craftCalls == 1, "switch and craft must be separate actions")
event("TRADE_SKILL_LIST_UPDATE")
advance(0)
FC.Execution.ProcessNext()
assert(switches == 1 and craftCalls == 1, "stale old profession event allowed a new cast or switch")
event("TRADE_SKILL_DATA_SOURCE_CHANGING")
open, sourceCounter = 197, 2
FC.Execution.ProcessNext()
assert(craftCalls == 1, "unready session could craft")
event("TRADE_SKILL_DATA_SOURCE_CHANGED")
advance(0)
FC.Execution.ProcessNext()
assert(craftCalls == 2 and watchedTask.status == "in_flight", "exact new session did not process")
event("UPDATE_TRADESKILL_CAST_STOPPED", false)
advance(3)
assert(watchedTask.status == "pending" and watchedTask.remainingExecutions == 1,
    "partial stop should credit exactly one confirmed execution and leave one pending")
mode = "complete"
FC.Execution.ProcessNext()
assert(craftCalls == 3 and nextJob.status == "complete", "remaining work did not finish from the saved task")

local variableJob = accept(555, 197, 1, "observed:variable")
recipe(555, 197)
mode = "variable"
FC.Execution.ProcessNext()
assert(craftCalls == 4 and variableJob.status == "complete",
    "exact native quantity within the guaranteed range failed to reconcile")

local uncertainJob = accept(444, 197, 1, "observed:3")
recipe(444, 197)
mode = "no-cast"
FC.Execution.ProcessNext()
output[1444] = 2
event("BAG_UPDATE_DELAYED")
assert(uncertainJob.tasks[1].status == "in_flight", "bag gain by itself credited the craft")
advance(180)
assert(uncertainJob.status == "running" and FC.Execution.IsBusy(),
    "elapsed time and a bare bag gain cannot close the active attempt")
FC.Execution.ProcessNext()
assert(craftCalls == 5, "an active attempt cannot be replayed while it lacks a terminal result")
FC.Execution.ReconcileUncertain()
assert(uncertainJob.status == "running", "manual inventory change qualified as native evidence")
FC.Queue.Initialize(saved)
loadModule("Execution")
FC.Execution.ProcessNext()
assert(craftCalls == 5 and uncertainJob.status == "uncertain", "reload restarted an uncertain craft")
assert(FC.Queue.Cancel(uncertainJob.id), "fixture could not clear reviewed work")

FC.target = "classic"
local legacyJob = accept(777, 197, 1, "observed:legacy")
recipe(777, 197).legacySpellID = 777
mode = "legacy"
FC.Execution.ProcessNext()
assert(craftCalls == 6 and legacyJob.status == "complete",
    "Classic exact cast GUID and bag delta failed to reconcile")

FC.target = "forever"
local retryJob = accept(817, 197, 1, "observed:unsubmitted")
recipe(817, 197)
retryJob.goal = nil -- An accepted job from before the goal field was persisted.
mode = "unsubmitted"
FC.Execution.ProcessNext()
assert(craftCalls == 7 and retryJob.status == "queued" and watchedTask.status == "pending"
    and watchedTask.completedExecutions == 0 and watchedTask.remainingExecutions == 1
    and not FC.Execution.IsBusy(), "a proven pre-submit rejection should leave retryable work")
mode = "complete"
FC.Execution.ProcessNext()
assert(craftCalls == 8 and retryJob.status == "complete", "a fresh click should finish the pending craft once")

local failedJob = accept(818, 197, 1, "observed:click-error")
recipe(818, 197)
mode = "click-error"
FC.Execution.ProcessNext()
assert(craftCalls == 9 and failedJob.status == "uncertain" and watchedTask.status == "uncertain",
    "an error after an attempted click cannot prove non-submission")
FC.Execution.ProcessNext()
assert(craftCalls == 9, "a potentially submitted craft must not be replayed")
assert(FC.Queue.Cancel(failedJob.id))

local directRecipe = recipe(900, open)
directRecipe.characterKey, directRecipe.completeness = FC.state.characterKey, "complete"
directRecipe.reagents = {{itemID = 9001, quantity = 1, slotIndex = 1}, {itemID = 9001, quantity = 1, slotIndex = 2}}
local alternate = {reagents = {{itemID = 9002, quantity = 1, slotIndex = 1}}}
local main = {reagents = directRecipe.reagents}
directRecipe.reagentChoices = {alternate, main}
local reserve = {status = "ready", revision = "reserved-by-other-job", rootRecipeId = 600, rootItemID = 1600,
    tree = {itemID = 1600, children = {{itemID = 9001, ownedUsed = 3}}},
    tasks = {{recipeId = 600, taskId = "t1", executions = 1}}, requirements = {}}
local reservedJob = assert(FC.Queue.Accept(reserve, function() return reserve end))
local function newestJob()
    local jobs = FC.Queue.GetJobs()
    return jobs[#jobs]
end

-- Direct Craft uses one execution, preserves the displayed reagent choice,
-- and does not touch the previously accepted work's reserves.
mode = "complete"
output[9001], output[9002] = 13, 20
local created, _, createdJob = FC.Execution.CraftSelected(900, false, main)
assert(created and createdJob == newestJob() and proposedBatch == 1
    and createdJob.tasks[1].completedExecutions == 1 and createdJob.status == "complete")
assert(newestJob().tasks[1].reagentChoice.reagents[1].itemID == 9001 and reservedJob.reservations["9001"] == 3)

output[9001] = 13
assert(FC.Execution.CraftSelected(900, false, main, 2))
assert(proposedBatch == 2 and newestJob().tasks[1].completedExecutions == 2 and newestJob().status == "complete",
    "the requested Craft amount must cap the real batch")

-- Two slots use the same item. Keep the other job's three units, and
-- continue the accepted remainder when the native button limits the first batch.
output[9001] = 13
nativeLimit = 3
local createdAll, _, createdAllJob = FC.Execution.CraftSelected(900, true, main)
assert(createdAll and createdAllJob == newestJob() and proposedBatch == 5 and createdAllJob.status == "queued")
assert(createdAllJob.tasks[1].executions == 5 and createdAllJob.tasks[1].completedExecutions == 3
    and createdAllJob.tasks[1].remainingExecutions == 2 and createdAllJob.reservations["9001"] == 4)
nativeLimit = nil
output[9001] = 7
assert(FC.Execution.ProcessNext(createdAllJob) and proposedBatch == 2 and createdAllJob.status == "complete"
    and createdAllJob.tasks[1].completedExecutions == 5 and next(createdAllJob.reservations) == nil)

local initialJobs, calls = #FC.Queue.GetJobs(), craftCalls
output[9001] = 4
assert(not FC.Execution.CraftSelected(900, false, main) and craftCalls == calls and #FC.Queue.GetJobs() == initialJobs,
    "a reserved slot must not become a purchase or switch to a different reagent choice")
assert(not FC.Execution.CraftSelected(900, true, main) and craftCalls == calls and #FC.Queue.GetJobs() == initialJobs,
    "Craft All cannot stage future crafts that need missing carries")

output[9001] = 13
mode = "changed-stock"
assert(not FC.Execution.CraftSelected(900, true, main) and #FC.Queue.GetJobs() == initialJobs,
    "changing stock between preparation and submission must not create a queue job")
output[9001] = 13
mode = "changed-session"
assert(not FC.Execution.CraftSelected(900, true, main) and #FC.Queue.GetJobs() == initialJobs,
    "an old profession generation must not create a queue job")
mode = "disabled"
assert(not FC.Execution.CraftSelected(900, true, main) and #FC.Queue.GetJobs() == initialJobs,
    "a disabled native action must not create a queue job")
mode = "unsubmitted"
for _ = 1, 2 do
    assert(not FC.Execution.CraftSelected(900, true, main) and #FC.Queue.GetJobs() == initialJobs,
        "proven non-submission must undo the provisional direct job")
end
mode = "click-error"
assert(not FC.Execution.CraftSelected(900, false, main) and newestJob().status == "uncertain")
calls = craftCalls
assert(not FC.Execution.CraftSelected(900, false, main) and craftCalls == calls,
    "uncertain native submission needs review before another direct craft")
assert(FC.Queue.Cancel(newestJob().id))

local function beginWaitingBatch(id, executions)
    local waitingJob = accept(id, open, executions, "observed:result-window:" .. id)
    local waitingRecipe = recipe(id, open)
    mode = "waiting"
    FC.Execution.ProcessNext()
    assert(waitingJob.status == "running" and waitingJob.tasks[1] == watchedTask)
    return waitingJob, waitingRecipe.outputItemID
end

local function observeOutput(itemID, operation)
    event("TRADE_SKILL_ITEM_CRAFTED_RESULT", {itemID = itemID, quantity = 2, operationID = operation})
    output[itemID] = (output[itemID] or 0) + 2
    event("BAG_UPDATE_DELAYED")
end

local foreignJob, foreignItem = beginWaitingBatch(950, 1)
local alternative = recipe(951, open)
alternative.outputItemID = foreignItem
event("TRADE_SKILL_CRAFT_BEGIN", alternative.id)
observeOutput(foreignItem, 951)
advance(1)
assert(foreignJob.status == "uncertain" and watchedTask.completedExecutions == 0,
    "another recipe producing the same item must not complete queued work")
assert(FC.Queue.Cancel(foreignJob.id))

local unsettledJob, unsettledItem = beginWaitingBatch(955, 2)
event("TRADE_SKILL_ITEM_CRAFTED_RESULT", {itemID = unsettledItem, quantity = 2, operationID = 955})
assert(watchedTask.evidence.matchedExecutions == 1 and not watchedTask.evidence.carriedResult)
alternative.outputItemID = unsettledItem
event("TRADE_SKILL_CRAFT_BEGIN", alternative.id)
observeOutput(unsettledItem, 956)
advance(1)
assert(unsettledJob.status == "uncertain" and not watchedTask.evidence.carriedResult,
    "another recipe's output cannot supply the missing carried confirmation for a previously matched partial result")
assert(FC.Queue.Cancel(unsettledJob.id))

local restartedJob, restartedItem = beginWaitingBatch(952, 1)
event("UPDATE_TRADESKILL_CAST_STOPPED", false)
event("TRADE_SKILL_CRAFT_BEGIN", 952)
observeOutput(restartedItem, 952)
advance(3)
assert(restartedJob.status == "uncertain" and watchedTask.completedExecutions == 0,
    "a new begin after the batch stops must not complete queued work")
assert(FC.Queue.Cancel(restartedJob.id))

local consecutiveJob, consecutiveItem = beginWaitingBatch(953, 2)
observeOutput(consecutiveItem, 0)
assert(watchedTask.status == "in_flight" and watchedTask.evidence.matchedExecutions == 1)
event("TRADE_SKILL_CRAFT_BEGIN", 953)
observeOutput(consecutiveItem, 0)
assert(consecutiveJob.status == "complete" and watchedTask.completedExecutions == 2)

local delayedJob, delayedItem = beginWaitingBatch(954, 2)
event("UPDATE_TRADESKILL_CAST_STOPPED", false)
advance(180)
assert(delayedJob.status == "running" and watchedTask.completedExecutions == 0,
    "a verified native stop waits for its outstanding matched receipt without a time limit")
observeOutput(delayedItem, 954)
assert(delayedJob.status == "queued" and watchedTask.completedExecutions == 1
    and watchedTask.remainingExecutions == 1, "late exact results must settle a stopped batch partially")
assert(FC.Queue.Cancel(delayedJob.id))

local reorderedJob, reorderedItem = beginWaitingBatch(956, 2)
observeOutput(reorderedItem, 9561)
event("TRADE_SKILL_CRAFT_BEGIN", 956)
event("UPDATE_TRADESKILL_CAST_STOPPED", false)
advance(180)
assert(reorderedJob.status == "running" and watchedTask.completedExecutions == 0)
output[reorderedItem] = 4
event("BAG_UPDATE_DELAYED")
event("TRADE_SKILL_ITEM_CRAFTED_RESULT", {itemID = reorderedItem, quantity = 2, operationID = 9562})
assert(reorderedJob.status == "complete" and watchedTask.completedExecutions == 2,
    "a final carried update and exact result following the native terminal can still finish the batch")

local missingResultJob, missingResultItem = beginWaitingBatch(957, 2)
observeOutput(missingResultItem, 9571)
event("TRADE_SKILL_CRAFT_BEGIN", 957)
event("UPDATE_TRADESKILL_CAST_STOPPED", false)
event("UNIT_SPELLCAST_SUCCEEDED", "party1", "foreign-cast", 957)
event("UNIT_SPELLCAST_SUCCEEDED", "player", "unrelated-cast", 956)
event("UNIT_SPELLCAST_SUCCEEDED", "player", "cast-spell-guid-" .. craftCalls, 957)
output[missingResultItem] = 4
event("BAG_UPDATE_DELAYED")
assert(missingResultJob.status == "running" and watchedTask.evidence.matchedExecutions == 1,
    "an unrelated full bag delta and duplicate spell event must not qualify missing proof")
event("UNIT_SPELLCAST_SUCCEEDED", "player", "exact-cast-2", 957)
assert(missingResultJob.status == "complete" and watchedTask.completedExecutions == 2
    and watchedTask.evidence.matchedExecutions == 2 and watchedTask.evidence.confirmedByExactCasts == 2
    and watchedTask.evidence.addonVersion == FC.version and watchedTask.evidence.clientBuild == FC.state.clientBuild,
    "the complete exact cast stream can corroborate a deterministic native batch without double counting item events")

assert(FC.Queue.Initialize({}))
local cooling = recipe(960, open)
local otherProfession = recipe(961, 171)
local ready = recipe(962, open)
local laterReady = recipe(963, open)
local function queueRecipe(row)
    row.characterKey, row.completeness, row.yieldMax, row.reagents = FC.state.characterKey, "complete", row.yield, {}
    local function preview()
        return FC.Planner.Preview({catalog = FC.Catalog.Snapshot(), rootRecipeId = row.id,
            characterKey = FC.state.characterKey, quantity = row.yield, now = now,
            revisions = {inventory = FC.InventoryAdapter.GetRevision()}})
    end
    return assert(FC.Queue.Accept(preview(), preview))
end
local coolingJob, otherJob = queueRecipe(cooling), queueRecipe(otherProfession)
local readyJob, laterJob = queueRecipe(ready), queueRecipe(laterReady)
local nativeCraft, nativeProfession = FC.Clients.Craft, FC.Clients.CurrentProfessionID
loadModule("Clients")
FC.Clients.Craft, FC.Clients.CurrentProfessionID = nativeCraft, nativeProfession
local changedTo, resolved = nil, {}
FC.Clients.SwitchProfession = function(id) changedTo = id; return true end
FC.Catalog.ReadModernRecipe = function(id)
    local row = recipes[id]
    resolved[id] = (resolved[id] or 0) + 1
    return {outputItemID = row.outputItemID, minYield = row.yield, maxYield = row.yieldMax,
        info = {}, schematic = {}, choices = {{reagents = row.reagents}},
        constraints = row == cooling and {cooldownUntil = now + 60} or {}}
end
mode = "complete"
calls = craftCalls
local _, blocker = FC.Execution.ProcessNext(coolingJob, coolingJob.tasks[1])
assert(blocker == FC.L.clients.cooldown and craftCalls == calls, "explicit tasks must keep their cooldown blocker")
_, blocker = FC.Execution.ProcessNext(coolingJob)
assert(blocker == FC.L.clients.cooldown and craftCalls == calls, "a preferred job cannot process a different job")
FC.Execution.ProcessNext()
assert(readyJob.status == "complete" and laterJob.status == "queued" and craftCalls == calls + 1)
assert(resolved[ready.id] == 1 and not changedTo and otherJob.status == "queued",
    "independent ready work must keep queue order and reuse the resolved native step")
FC.Execution.ProcessNext()
assert(laterJob.status == "complete" and resolved[laterReady.id] == 1 and craftCalls == calls + 2)
do
    queueRecipe(recipe(964, 185))
    local _, _, target, phase, task = FC.Execution.ProcessClick()
    assert(changedTo == otherProfession.professionId and craftCalls == calls + 2
        and target == otherJob and phase == "profession_switch" and task == otherJob.tasks[1],
        "a cooling local craft allows Process to open the first ready other profession")
    assert(not FC.Execution.ProcessClick() and craftCalls == calls + 2,
        "a further click during the native switch must wait for readiness")
end

loadModule("Execution")
local blockedCases = {
    {reason = FC.L.execRecipeChanged, change = function(row) row.revision = row.revision + 1 end},
    {reason = FC.L.execNotLearned, change = function(row) row.learned = false end},
    {reason = FC.L.execWrongActor, change = function(_, job) job.characterKey = "other-actor" end},
    {reason = FC.L.clients.staleYield, change = function(row) row.liveOutputItemID = row.outputItemID + 1 end},
    {reason = FC.L.clients.supersededRank, invalidates = true, change = function(row)
        row.supersededByRecipeID, row.blockedReason = row.recipeID + 1, FC.L.clients.supersededRank
    end},
}
local readRecipe = FC.Catalog.ReadModernRecipe
FC.Catalog.ReadModernRecipe = function(id)
    local live = readRecipe(id)
    live.outputItemID = recipes[id].liveOutputItemID or live.outputItemID
    return live
end
for index, case in ipairs(blockedCases) do
    assert(FC.Queue.Initialize({}))
    changedTo, calls = nil, craftCalls
    local blocked = recipe(970 + index, open)
    local blockedJob = queueRecipe(blocked)
    local elsewhere = queueRecipe(otherProfession)
    case.change(blocked, blockedJob)

    local qualified = recipe(980 + index, open)
    local qualifiedJob = queueRecipe(qualified)
    local ok, why = FC.Execution.ProcessNext(blockedJob, blockedJob.tasks[1])
    assert(not ok and why == case.reason and craftCalls == calls, "an explicit task cannot dispatch a sibling")
    ok, why = FC.Execution.ProcessNext(blockedJob)
    assert(not ok and why == case.reason and craftCalls == calls, "a preferred job cannot dispatch another job")

    ok, why = FC.Execution.ProcessNext()
    assert(ok and why == FC.L.execReconciled and qualifiedJob.status == "complete" and craftCalls == calls + 1,
        "Process should dispatch and report success for the next qualified craft")
    assert(resolved[qualified.id] == 1 and blockedJob.status == (case.invalidates and "invalidated" or "queued")
        and elsewhere.status == "queued"
        and not changedTo, "prefer qualified work in the open profession and reuse its native resolution")
end

assert(FC.Queue.Initialize({}))
changedTo, calls = nil, craftCalls
local closedRank = recipe(992, otherProfession.professionId)
local closedRankJob = queueRecipe(closedRank)
closedRank.supersededByRecipeID, closedRank.blockedReason = 993, FC.L.clients.supersededRank
local _, rankBlocker = FC.Execution.ProcessNext()
assert(rankBlocker == FC.L.clients.supersededRank and closedRankJob.status == "invalidated"
    and not changedTo and craftCalls == calls, "a known superseded exact rank cannot trigger a profession switch")

assert(FC.Queue.Initialize({}))
local localRank = recipe(993, open)
local localRankJob = queueRecipe(localRank)
local fartherJob = queueRecipe(otherProfession)
local eligibleJob = queueRecipe(recipe(994, open))
localRank.supersededByRecipeID, localRank.blockedReason = 995, FC.L.clients.supersededRank
assert(FC.Execution.ProcessNext() and eligibleJob.status == "complete" and craftCalls == calls + 1
    and localRankJob.status == "invalidated" and fartherJob.status == "queued" and not changedTo,
    "the same Process press skips only to independent work in the open profession")

assert(FC.Queue.Initialize({}))
local peer = assert(FC.Queue.Accept(reserve, function() return reserve end))
local guarded = recipe(996, open)
guarded.characterKey, guarded.completeness, guarded.yieldMax = FC.state.characterKey, "complete", guarded.yield
guarded.reagents = {{itemID = 9001, quantity = 2, slotIndex = 1}}
output[9001] = 7
local function guardPreview()
    return FC.Planner.Preview({catalog = FC.Catalog.Snapshot(), rootRecipeId = guarded.id,
        characterKey = FC.state.characterKey, quantity = 4, now = now,
        inventory = FC.Queue.AvailableInventory({[9001] = output[9001]})})
end
local guardedJob = assert(FC.Queue.Accept(guardPreview(), guardPreview))
local guardedTask, submitted = guardedJob.tasks[1], false
FC.Clients.Craft = function(task, _, batch, beforeClick)
    assert(task == guardedTask and batch == 2)
    output[9001] = 5 -- Native still sees enough total stock for two crafts.
    if not beforeClick(batch) then return false, FC.L.clients.queueIntent end
    submitted = true
    return true, nil, batch
end
local started, why = FC.Execution.ProcessNext(guardedJob, guardedTask)
assert(not started and why == FC.L.execMissingMaterials and not submitted and guardedTask.status == "pending"
    and not guardedTask.evidence and peer.reservations["9001"] == 3,
    "an accepted batch must preserve another job's reserves when inputs change during native preparation")
assert(#guardedJob.tasks == 1 and not FC.Execution.GetReadyRestockCraft(guardedJob),
    "a partially supplied single-step order still needs its full allocation before the Restock button offers it")
FC.Clients.Craft = nativeCraft
assert(FC.Execution.ProcessNext(guardedJob, guardedTask) and guardedTask.completedExecutions == 1
    and guardedTask.remainingExecutions == 1 and peer.reservations["9001"] == 3,
    "a fresh Process click can use only the currently unreserved inputs")

output[9001] = 3
assert(FC.Queue.SetPaused(peer.id, true))
local remote = queueRecipe(otherProfession)
changedTo, calls = nil, craftCalls
local independent = queueRecipe(recipe(997, open))
started, why = FC.Execution.ProcessNext(guardedJob)
assert(not started and why == FC.L.execMissingMaterials and craftCalls == calls,
    "a selected job must retain its missing-reagent blocker")
started, why = FC.Execution.ProcessNext(guardedJob, guardedTask)
assert(not started and why == FC.L.execMissingMaterials and craftCalls == calls,
    "a selected task cannot process a different recipe when its reagents are missing")
assert(FC.Execution.ProcessNext() and independent.status == "complete" and craftCalls == calls + 1
    and not changedTo and remote.status == "queued" and guardedTask.remainingExecutions == 1,
    "unpreferred Process should use available materials on another ready task in the open profession")
do (function()
    local expected = assert(FC.Execution.GetRestockProfession())
    assert(expected.jobId == remote.id and expected.professionID == otherProfession.professionId
        and not FC.Execution.GetReadyRestockCraft(), "a blocked local craft leaves the exact remote HUD opener")
    local priorCasting = UnitCastingInfo
    UnitCastingInfo = function() return "Another native craft" end
    assert(not FC.Execution.GetRestockProfession() and not FC.Execution.ProcessClick() and not changedTo,
        "opening another profession must not interrupt an unrelated native cast")
    UnitCastingInfo = priorCasting
    local _, _, job, phase = FC.Execution.ProcessClick()
    assert(job == remote and phase == "profession_switch" and changedTo == otherProfession.professionId
        and craftCalls == calls + 1, "the general Process can switch past a local shortage without submitting")
    local previous = open
    open = otherProfession.professionId
    event("TRADE_SKILL_DATA_SOURCE_CHANGED")
    advance(0)
    assert(FC.Execution.GetReadyRestockCraft() == remote.tasks[1] and craftCalls == calls + 1)
    open = previous
    event("TRADE_SKILL_CLOSE")
    advance(0)
end)() end

do
    assert(FC.Queue.Initialize({}))
    local blocked, carried = recipe(9971, open), recipe(9972, open)
    blocked.reagents = {{itemID = 9011, quantity = 2, slotIndex = 1}}
    carried.reagents = {}
    blocked.completeness, blocked.yieldMax = "complete", blocked.yield
    carried.completeness, carried.yieldMax = "complete", carried.yield
    local function branch(row, id, inputs)
        return {taskId = id, recipeId = row.id, professionId = row.professionId,
            outputItemID = row.outputItemID, outputKind = "item", yield = row.yield,
            outputQuantity = row.yield, executions = 1, recipeRevision = 1, dependencies = {}, inputs = inputs}
    end
    local plan = {status = "ready", revision = "carried-branches", rootRecipeId = carried.id,
        rootItemID = carried.outputItemID, summary = {output = 2}, requirements = {},
        tree = {itemID = carried.outputItemID, source = "Make", required = 2, children = {}},
        tasks = {branch(blocked, "short", blocked.reagents), branch(carried, "carried", {})}}
    local branches = assert(FC.Queue.Accept(plan, function() return plan end))
    local short, readyBranch = branches.tasks[1], branches.tasks[2]
    assert(not FC.Execution.GetReadyRestockCraft(branches), "a ready branch cannot open a partially supplied job")
    local ok, reason = FC.Execution.ProcessNext(branches, short)
    assert(not ok and reason == FC.L.execMissingMaterials and readyBranch.status == "pending",
        "an explicit Flowchart task keeps its exact missing-input reason")
    assert(not FC.Execution.ProcessNext(branches, readyBranch) and not FC.Execution.ProcessNext(branches)
        and readyBranch.status == "pending", "Flowchart and general Process both wait for all job inputs")
    local originalProfession = FC.Clients.CurrentProfessionID
    FC.Clients.CurrentProfessionID = function() end
    assert(not FC.Execution.GetRestockProfession(), "a closed profession cannot appear before every job input is carried")
    output[9011] = 2
    local opening = assert(FC.Execution.GetRestockProfession())
    assert(opening.jobId == branches.id and opening.taskId == short.taskId)
    output[9011] = 0
    assert(not FC.Execution.OpenRestockProfession(opening), "the HUD rechecks carried stock before opening")
    FC.Clients.CurrentProfessionID = originalProfession
    output[9011] = 2
    assert(FC.Execution.GetReadyRestockCraft(branches) == short and FC.Execution.ProcessNext(branches, readyBranch)
        and readyBranch.status == "complete", "a complete carried job enables the original exact Flowchart choice")
end

assert(FC.Queue.Initialize({}))
peer = assert(FC.Queue.Accept(reserve, function() return reserve end))
local reviewJob = accept(998, open, 1, "observed:queue-all-review")
local reviewTask = reviewJob.tasks[1]
assert(FC.Queue.Begin(reviewJob, reviewTask, {beforeOutput = 0, batch = 1}))
FC.Queue.MarkUncertain(reviewJob, reviewTask)
FC.state.db = {}
loadModule("Pricing")
loadModule("Logistics")
FC.MarketAdapter = {QuoteItems = function()
    return {[9001] = {itemID = 9001, unitPrice = 15, source = "fixture"},
        [guarded.outputItemID] = {itemID = guarded.outputItemID, unitPrice = 70, source = "fixture"}}
end}
local resolveRecipe = FC.Catalog.ReadModernRecipe
FC.Catalog.ReadModernRecipe = function(id)
    local live = resolveRecipe(id)
    live.constraints.maxExecutions = 3
    return live
end
output[9001], calls = 13, craftCalls
local queuedAll, reason, details = FC.Execution.QueueAllSelected(guarded.id)
assert(queuedAll, tostring(reason))
assert(queuedAll.status == "queued" and queuedAll.tasks[1].executions == 3 and not queuedAll.tasks[1].evidence
    and queuedAll.summary.requested == 6 and queuedAll.summary.fullValue == 90 and #queuedAll.requirements == 0
    and not queuedAll.goal.directCraft and not queuedAll.goal.autoBuyVendor and details.projection.estimatedProfit == 309
    and peer.reservations["9001"] == 3 and queuedAll.reservations["9001"] == 6 and craftCalls == calls
    and reviewJob.status == "uncertain",
    "Queue All must reserve the qualified carried-only maximum and capture its price without crafting")
output[9001] = 3
local absent, missing = FC.Execution.QueueAllSelected(guarded.id)
assert(not absent and missing == FC.L.planner.bags and #FC.Queue.GetJobs() == 3 and craftCalls == calls,
    "Queue All must not create an unbounded purchase when no unreserved materials are available")

do
    assert(FC.Queue.Initialize({}))
    local stationRecipe = recipe(12067, open)
    stationRecipe.outputItemID = 10019
    stationRecipe.characterKey, stationRecipe.completeness = FC.state.characterKey, "complete"
    stationRecipe.yieldMax = stationRecipe.yield
    stationRecipe.reagents = {{itemID = 9001, quantity = 2, slotIndex = 1}}
    local station = "Spinning Wheel"
    local required = FC.L.clients.requires:format(station)
    stationRecipe.constraints = {requirementsMet = false, requirements = {{name = station, met = false, kind = 0}}}
    local previousRead, stationAvailable = FC.Catalog.ReadModernRecipe, false
    FC.Catalog.ReadModernRecipe = function(id)
        local live = previousRead(id)
        live.constraints = {requirementsMet = stationAvailable,
            requirements = {{name = station, met = stationAvailable, kind = 0}}}
        return live
    end
    output[9001], output[stationRecipe.outputItemID] = 2, 0
    local previousCrafts = craftCalls
    local plan = FC.Logistics.Preview({recipeId = stationRecipe.id, quantity = stationRecipe.yield,
        deferRecipeRequirements = true})
    assert(plan.status == "ready" and plan.craftRequirement == required and #plan.tasks == 1)
    local ok, reason, job = FC.Execution.CreateSelected(stationRecipe.id, stationRecipe.yield, nil, nil, true)
    assert(ok and reason == required and job and job.status == "queued" and #FC.Queue.GetJobs() == 1
        and craftCalls == previousCrafts, "Create queues the explicit recipe while the native station is unavailable")
    local task = job.tasks[1]
    ok, reason = FC.Execution.ProcessClick(job, task)
    assert(not ok and reason == required and task.status == "pending" and not task.evidence
        and not FC.Execution.GetReadyRestockCraft(job) and craftCalls == previousCrafts)
    stationAvailable = true
    local ready, batch, owner = FC.Execution.GetReadyRestockCraft(job)
    assert(ready == task and batch == 1 and owner == job, "live station readiness takes precedence over the catalog")
    assert(FC.Execution.ProcessClick(owner, ready) and craftCalls == previousCrafts + 1
        and job.status == "complete" and task.completedExecutions == 1,
        "the exact queued recipe completes once the native station is available")
    FC.Catalog.ReadModernRecipe = previousRead
end

do
    assert(FC.Queue.Initialize({}))
    local oldCatalog, oldTrade = FC.Catalog.Snapshot, C_TradeSkillUI
    local root, bolt = recipe(12079, open), recipe(3865, open)
    root.outputItemID, root.yield, root.yieldMax, root.completeness = 10051, 1, 1, "complete"
    root.characterKey, bolt.characterKey = FC.state.characterKey, FC.state.characterKey
    root.reagents = {{itemID = 4339, quantity = 5}, {itemID = 2604, quantity = 2}, {itemID = 8343, quantity = 2}}
    bolt.outputItemID, bolt.yield, bolt.yieldMax, bolt.completeness = 4339, 1, 1, "complete"
    bolt.reagents = {{itemID = 4338, quantity = 5}}
    local catalog = {recipesById = recipes, byOutput = {[4339] = {3865}, [10051] = {12079}}, revision = 90}
    FC.Catalog.Snapshot = function() return catalog end
    local recasts = 0
    C_TradeSkillUI = {GetRemainingRecasts = function() return recasts end}
    local function preview()
        return FC.Logistics.Preview({recipeId = 12079, quantity = 5, bagsOnly = true, autoBuyVendor = false})
    end
    local function stoppedJob()
        assert(FC.Queue.Initialize({}))
        output[4338], output[4339], output[2604], output[8343] = 125, 0, 10, 10
        local previousPlan = preview()
        assert(previousPlan.status == "ready", previousPlan.blocker)
        local oldJob = assert(FC.Queue.Accept(previousPlan, preview))
        local failed = oldJob.tasks[1]
        assert(failed.recipeId == 3865 and failed.remainingExecutions == 25 and oldJob.tasks[2].remainingExecutions == 5)
        local settledAuction = {kind = "auction", requirementId = "old-1", quantity = 2, remaining = 0,
            auctionAwaiting = 0, auctionSpent = 992, itemID = 4338}
        oldJob.requirements[1] = settledAuction
        assert(FC.Queue.Begin(oldJob, failed, {batch = 25, beforeOutput = 0, maxYield = 1,
            recipeId = failed.recipeId, professionId = failed.professionId}))
        local journal = failed.evidence
        journal.clientBuild = tostring(journal.clientBuild)
        journal.addonVersion, journal.dispatch = "0.2.45-dev", "process"
        FC.Queue.MarkUncertain(oldJob, failed, FC.L.execTimedOut)
        return oldJob, failed, journal, settledAuction
    end
    local oldJob, failed, journal, settledAuction = stoppedJob()

    local recoverySkill, previousCrafts = open, craftCalls
    open = recoverySkill == 197 and 171 or 197
    assert(FC.Execution.GetRecoveryProfession(oldJob) == recoverySkill and not FC.Execution.CanReplanFromBags(oldJob))
    local shownRecovery = assert(FC.Execution.GetRestockProfession())
    assert(shownRecovery.jobId == oldJob.id and shownRecovery.taskId == failed.taskId
        and shownRecovery.professionID == recoverySkill and not FC.Execution.GetReadyRestockCraft())
    local opened, _, openingJob, phase, openingTask = FC.Execution.OpenRestockProfession(shownRecovery)
    assert(opened and openingJob == oldJob and phase == "profession_switch" and openingTask == failed
        and changedTo == recoverySkill and oldJob.status == "uncertain" and not FC.Execution.CanReplanFromBags(oldJob))
    open = recoverySkill
    recasts = 13
    event("TRADE_SKILL_DATA_SOURCE_CHANGED")
    advance(0)
    assert(oldJob.status == "uncertain" and craftCalls == previousCrafts and not FC.Execution.GetRecoveryProfession(oldJob),
        "opening the exact historical craft profession cannot recover while native recasts remain active")

    output[4338], output[4339] = 65, 12
    recasts = 13
    assert(not FC.Execution.CanReplanFromBags(oldJob) and not FC.Execution.ReplanFromBags(oldJob))
    recasts = 0
    settledAuction.auctionAwaiting = 1
    assert(not FC.Execution.CanReplanFromBags(oldJob) and not FC.Execution.ReplanFromBags(oldJob))
    settledAuction.auctionAwaiting = 0
    assert(FC.Execution.CanReplanFromBags(oldJob) and not FC.Queue.CanReplace(oldJob))
    output[4338] = 60
    assert(not FC.Execution.ReplanFromBags(oldJob) and oldJob.status == "uncertain" and #FC.Queue.GetJobs() == 1,
        "recovery cannot buy the missing cloth or leave a partially accepted replacement")
    output[4338] = 65
    local beforeCalls = craftCalls
    local ok, _, replacement = FC.Execution.ReplanFromBags(oldJob)
    assert(ok and replacement.status == "queued" and oldJob.status == "replaced"
        and replacement.replaces == oldJob.id and oldJob.replacement == replacement.id
        and failed.evidence == journal and failed.completedExecutions == 0
        and oldJob.requirements[1] == settledAuction and settledAuction.auctionSpent == 992
        and next(oldJob.reservations) == nil and #FC.Queue.GetJobs() == 2 and craftCalls == beforeCalls,
        "explicit bags replan retains the previous attempt and settled purchase without credit or spending")
    assert(replacement.tasks[1].recipeId == 3865 and replacement.tasks[1].remainingExecutions == 13
        and replacement.tasks[2].recipeId == 12079 and replacement.tasks[2].remainingExecutions == 5
        and replacement.reservations["4339"] == 12 and replacement.reservations["4338"] == 65
        and #replacement.requirements == 0 and not FC.Execution.CanReplanFromBags(oldJob),
        "the new five-bag order uses 12 carried bolts and prepares just the remaining 13")
    advance(0)

    local originalOn, originalEmit, originalPreview = FC.On, FC.Emit, FC.Logistics.Preview
    local handlers, recovered, recoveryPreviews = {}, 0, 0
    function FC:On(signal, callback) handlers[signal] = callback end
    loadModule("Execution")
    FC.On = originalOn
    function FC:Emit(signal, ...)
        if signal == "CRAFT_RECOVERY_REPLANNED" then recovered = recovered + 1 end
        if handlers[signal] then handlers[signal](self, ...) end
        return originalEmit(self, signal, ...)
    end
    function FC.Logistics.Preview(args, ...)
        if args.replaces and args.bagsOnly then recoveryPreviews = recoveryPreviews + 1 end
        return originalPreview(args, ...)
    end

    oldJob, failed, journal, settledAuction = stoppedJob()
    output[4338], output[4339] = 60, 12
    beforeCalls = craftCalls
    FC:Emit("QUEUE_CHANGED")
    FC.Execution.InventoryChanged({reliable = true})
    advance(0)
    assert(oldJob.status == "uncertain" and recoveryPreviews == 1 and recovered == 0 and craftCalls == beforeCalls,
        "coalesced signals do one silent recovery check and leave insufficient cloth under review")
    output[4338] = 65
    FC.Execution.InventoryChanged({reliable = true})
    event("BAG_UPDATE_DELAYED")
    event("TRADE_SKILL_LIST_UPDATE")
    advance(0)
    local automatic = assert(FC.Queue.GetJob(oldJob.replacement))
    assert(oldJob.status == "replaced" and failed.evidence == journal and recoveryPreviews == 3 and recovered == 1
        and automatic.tasks[1].remainingExecutions == 13 and automatic.tasks[2].remainingExecutions == 5
        and craftCalls == beforeCalls and not automatic.tasks[1].evidence,
        "bags-only recovery accepts exactly once and does not craft or buy in the background")

    oldJob = stoppedJob()
    output[4338], output[4339] = 65, 12
    local originalResolve, originalCanDispatch, originalDispatch = FC.Clients.Resolve,
        FC.Clients.CanDispatchQueuedCraft, FC.Clients.DispatchQueuedCraft
    local presses = 0
    FC.Clients.Resolve = function(task)
        return {kind = "forever", recipeID = task.recipeId, maxYield = task.yield}
    end
    FC.Clients.CanDispatchQueuedCraft = function() return true end
    FC.Clients.DispatchQueuedCraft = function(task, _, batch, beforeClick)
        presses = presses + 1
        assert(oldJob.status == "replaced" and task.recipeId == 3865 and batch == 13 and beforeClick(batch))
        output[4338], output[4339] = 0, 25
        event("TRADE_SKILL_CRAFT_BEGIN", task.recipeId)
        event("TRADE_SKILL_ITEM_CRAFTED_RESULT", {itemID = task.outputItemID, quantity = batch, operationID = 3865})
        event("BAG_UPDATE_DELAYED")
        return true, nil, batch
    end
    local dispatched, _, continued, craftPhase = FC.Execution.ProcessClick(oldJob)
    advance(0)
    assert(dispatched and craftPhase == "dispatched" and continued.id == oldJob.replacement and recovered == 2
        and presses == 1 and continued.tasks[1].status == "complete" and continued.tasks[2].status == "pending",
        "an explicit Process can continue exactly one recovered batch before the scheduled replan runs")
    FC.Clients.Resolve, FC.Clients.CanDispatchQueuedCraft, FC.Clients.DispatchQueuedCraft =
        originalResolve, originalCanDispatch, originalDispatch
    FC.Emit, FC.Logistics.Preview = originalEmit, originalPreview
    FC.Catalog.Snapshot, C_TradeSkillUI = oldCatalog, oldTrade
end

local reviewSave = {}
assert(FC.Queue.Initialize(reviewSave))
FC.Clients.Resolve = function(task)
    return {kind = "forever", recipeID = task.recipeId, maxYield = task.yield}
end
local witnessed, witnessedItem = beginWaitingBatch(991, 2)
local witnessedTask = witnessed.tasks[1]
observeOutput(witnessedItem, 991)
assert(witnessedTask.status == "in_flight" and witnessedTask.evidence.carriedResult.outputCount == 2
    and witnessedTask.evidence.carriedResult.executions == 1,
    "the exact result and matching carried delta must both survive a mid-batch reload")
assert(FC.Queue.Initialize(reviewSave))
loadModule("Execution")
output[witnessedItem] = 0

local unwitnessed = accept(992, open, 2, "observed:missing-carried-proof")
local unwitnessedTask = unwitnessed.tasks[1]
assert(FC.Queue.Begin(unwitnessed, unwitnessedTask, {beforeOutput = 0, batch = 2, maxYield = 2}))
FC.Queue.CraftEvent(unwitnessed, unwitnessedTask, 1, 2)
assert(FC.Queue.Initialize(reviewSave))
output[unwitnessedTask.outputItemID] = 2 -- A separate item gain after reload.
local _, unresolved = FC.Execution.ReconcileUncertain(unwitnessed)
assert(unresolved == FC.L.execUnproved and unwitnessedTask.completedExecutions == 0
    and witnessed.status == "uncertain", "explicit review must reject later bag gains and must stay on its selected job")
_, unresolved = FC.Execution.ReconcileUncertain({id = witnessed.id, tasks = witnessed.tasks})
assert(unresolved == FC.L.execNothingToReview and witnessed.status == "uncertain", "review must use the exact saved job")
FC.state.characterKey = "actor-B"
_, unresolved = FC.Execution.ReconcileUncertain(witnessed)
assert(unresolved == FC.L.execWrongActor and witnessed.status == "uncertain")
FC.state.characterKey, FC.state.build = "actor-A", 11509
_, unresolved = FC.Execution.ReconcileUncertain(witnessed)
assert(unresolved == FC.L.execWrongActor and witnessed.status == "uncertain")
FC.state.build = 16001
FC.Execution.ReconcileUncertain()
assert(witnessedTask.completedExecutions == 1 and witnessedTask.remainingExecutions == 1
    and witnessedTask.evidence.afterOutput == 2 and witnessed.status == "queued",
    "review must credit previously witnessed carry once even if that output was subsequently used")
_, unresolved = FC.Execution.ReconcileUncertain(witnessed)
assert(unresolved == FC.L.execNothingToReview and witnessedTask.completedExecutions == 1 and unwitnessed.status == "uncertain")
assert(FC.Queue.Cancel(unwitnessed.id) and unwitnessedTask.evidence.matchedExecutions == 1,
    "explicit removal of an unproved batch must preserve its work history")

-- The observed Free Action Potion plan recorded nine of ten oil crafts,
-- while all ten oils were carried and there were no reagents for a recast.
local recoverySave = {}
assert(FC.Queue.Initialize(recoverySave))
local oil = recipe(7836, open)
oil.outputItemID, oil.yield, oil.yieldMax = 6370, 1, 1
oil.characterKey, oil.completeness = FC.state.characterKey, "complete"
oil.reagents = {{itemID = 6358, quantity = 2}, {itemID = 3371, quantity = 1}}
local potion = recipe(6624, open)
potion.outputItemID, potion.yield, potion.yieldMax = 5634, 1, 1
potion.characterKey, potion.completeness = FC.state.characterKey, "complete"
potion.reagents = {{itemID = 6370, quantity = 2}, {itemID = 3820, quantity = 1}, {itemID = 3372, quantity = 1}}
FC.Catalog.Snapshot = function() return {recipesById = recipes, byOutput = {[oil.outputItemID] = {oil.id}}} end
FC.MarketAdapter.QuoteItems = function()
    return {[6358] = 1, [3371] = 1, [3820] = 1, [3372] = 1, [6370] = 10}
end
output[6358], output[3371], output[3820], output[3372], output[6370], output[5634] = 0, 0, 0, 0, 0, 0
local function originalPlan()
    return FC.Logistics.Preview({recipeId = potion.id, quantity = 5, choices = {[6370] = {source = "Make"}}})
end
local original = assert(FC.Queue.Accept(originalPlan(), originalPlan))
local oilTask, potionTask = original.tasks[1], original.tasks[2]
assert(oilTask.recipeId == 7836 and oilTask.executions == 10 and potionTask.executions == 5)
for index, requirement in ipairs(original.requirements) do
    output[requirement.itemID] = requirement.quantity
    assert(FC.Queue.CreditAcquisition(original, index, requirement.quantity, requirement.quantity) == requirement.quantity)
end
assert(FC.Queue.Begin(original, oilTask, {beforeOutput = 0, batch = 10, maxYield = 1}))
FC.Queue.CraftEvent(original, oilTask, 9, 9)
assert(not FC.Queue.Reconcile(original, oilTask, 9) and oilTask.evidence.carriedResult)
FC.Queue.MarkUncertain(original, oilTask)
assert(FC.Queue.ReconcilePartial(original, oilTask))
output[6358], output[3371], output[6370] = 0, 0, 10
assert(FC.Queue.Initialize(recoverySave))

local rival = {status = "ready", revision = "recovery-other-job", rootRecipeId = 955, rootItemID = 1955,
    tree = {itemID = 1955, children = {{itemID = 6370, ownedUsed = 1}}}, requirements = {},
    tasks = {{recipeId = 955, taskId = "t1", executions = 1}}}
local rivalJob = assert(FC.Queue.Accept(rival, function() return rival end))
local _, recoveryBlocker = FC.Execution.ProcessNext(original)
assert(recoveryBlocker == FC.L.execMissingMaterials and original.status == "queued" and not original.replacement,
    "another job's reservation cannot fund carried recovery")
assert(FC.Queue.Cancel(rivalJob.id))
_, recoveryBlocker = FC.Execution.ProcessNext(original, oilTask)
assert(recoveryBlocker == FC.L.execMissingMaterials and not original.replacement,
    "an explicit subcraft request keeps the exact missing-material blocker")

local changeBeforeClick = true
FC.Clients.Craft = function(task, _, batch, beforeClick)
    assert(task.recipeId == 6624 and batch == 5)
    if changeBeforeClick then
        output[6370] = 9
        assert(not beforeClick(batch), "carried recovery must recheck full stock just before dispatch")
        return false, FC.L.clients.queueIntent
    end
    assert(beforeClick(batch))
    output[6370], output[3820], output[3372], output[5634] = 0, 0, 0, 5
    event("TRADE_SKILL_CRAFT_BEGIN", 6624)
    event("TRADE_SKILL_ITEM_CRAFTED_RESULT", {itemID = 5634, quantity = 5, operationID = 6624})
    return true, nil, batch
end
assert(not FC.Execution.ProcessNext(original) and original.status == "queued" and not original.replacement)
output[6370], changeBeforeClick = 10, false
local recovered, _, replacement = FC.Execution.ProcessNext(original)
assert(recovered and replacement.replaces == original.id and original.status == "replaced"
    and replacement.status == "complete" and replacement.tasks[1].completedExecutions == 5
    and #replacement.requirements == 0 and next(original.reservations) == nil
    and original.producedReservations["6370"] == nil and next(replacement.reservations) == nil
    and oilTask.completedExecutions == 9 and oilTask.evidence.matchedExecutions == 9,
    "physical oil supports the exact remaining root without inventing a tenth historical operation")

-- Native form preparation, initial queue acceptance and the intent
-- notification can each publish a carried change before native submission.
assert(FC.Queue.Initialize({}))
local baselineRecipe = recipe(986, open)
baselineRecipe.characterKey, baselineRecipe.completeness, baselineRecipe.yieldMax = FC.state.characterKey, "complete", 2
baselineRecipe.reagents = {{itemID = 9010, quantity = 1}}
local baselineItem = baselineRecipe.outputItemID
output[9010], output[baselineItem] = 1, 0
local preparing, unavailableAtIntent, unavailable, presses = true, false, false, 0
local count = FC.InventoryAdapter.Count
FC.InventoryAdapter.Count = function(id)
    if id == baselineItem and unavailable then return nil, "Inventory changed before Create." end
    return count(id)
end
function FC:Emit(signal)
    if signal ~= "QUEUE_CHANGED" then return end
    local job = newestJob()
    if not job or job.rootRecipeId ~= baselineRecipe.id then return end
    if preparing and job.status == "queued" then output[baselineItem] = 2 end
    if job.status == "running" then
        if preparing then output[baselineItem] = 3 end
        if unavailableAtIntent then unavailable = true end
    end
end
FC.Clients.Craft = function(task, _, batch, beforeClick)
    assert(task.recipeId == baselineRecipe.id and batch == 1)
    if preparing then output[baselineItem] = 1 end
    if not beforeClick(batch) then return false, FC.L.clients.queueIntent end
    presses = presses + 1
    assert(newestJob().tasks[1].evidence.beforeOutput == 3)
    event("TRADE_SKILL_CRAFT_BEGIN", baselineRecipe.id)
    event("TRADE_SKILL_ITEM_CRAFTED_RESULT", {itemID = baselineItem, quantity = 2, operationID = 986})
    output[baselineItem] = 5
    event("BAG_UPDATE_DELAYED")
    return true, nil, batch
end
local baselineStarted, _, baselineJob = FC.Execution.CraftSelected(baselineRecipe.id, false)
assert(baselineStarted and baselineJob.status == "complete" and presses == 1
    and baselineJob.tasks[1].evidence.beforeOutput == 3 and baselineJob.tasks[1].evidence.afterOutput == 5,
    "reordered pre-click output publications must be outside the exact craft delta")

preparing, unavailableAtIntent = false, true
local prior = #FC.Queue.GetJobs()
local rejected, missingBaseline, unsubmittedJob = FC.Execution.CraftSelected(baselineRecipe.id, false)
assert(not rejected and missingBaseline == "Inventory changed before Create." and not unsubmittedJob
    and presses == 1 and #FC.Queue.GetJobs() == prior and not FC.Execution.IsBusy(),
    "an unavailable final baseline must discard an unsubmitted provisional Create job")

unavailable = false
local queued = accept(986, open, 1, "unavailable-baseline")
rejected, missingBaseline = FC.Execution.ProcessNext(queued)
assert(not rejected and missingBaseline == "Inventory changed before Create." and presses == 1
    and queued.status == "queued" and queued.tasks[1].status == "pending"
    and not queued.tasks[1].evidence and not FC.Execution.IsBusy(),
    "an unavailable final baseline leaves an accepted job pending without a replayable attempt")

-- A data-source notification can precede the ready native profession.
-- A later provider publication can settle the switch without pressing Create.
assert(FC.Queue.Initialize({}))
unavailable, unavailableAtIntent = false, false
loadModule("Execution")
local observedProfession, observedSource = 171, 1
local switchRequests, nativePresses = 0, 0
FC.Clients.CurrentProfessionID = function() return observedProfession, observedSource end
FC.Clients.SwitchProfession = function(id)
    assert(id == 197)
    switchRequests = switchRequests + 1
    return true
end
FC.Clients.Craft = function(task, _, batch, beforeClick)
    assert(observedProfession == 197 and batch == 1 and beforeClick(batch))
    nativePresses = nativePresses + 1
    event("TRADE_SKILL_CRAFT_BEGIN", task.recipeId)
    output[task.outputItemID] = (output[task.outputItemID] or 0) + 2
    event("TRADE_SKILL_ITEM_CRAFTED_RESULT", {itemID = task.outputItemID, quantity = 2, operationID = task.recipeId})
    return true, nil, batch
end

local function beginSwitch(id)
    observedProfession = 171
    local job = accept(id, 197, 1, "late-profession-ready")
    recipe(id, 197)
    local pressed = nativePresses
    assert(not FC.Execution.ProcessNext(job) and FC.Execution.IsBusy() and nativePresses == pressed)
    event("TRADE_SKILL_DATA_SOURCE_CHANGING")
    observedProfession = nil
    event("TRADE_SKILL_DATA_SOURCE_CHANGED")
    advance(0)
    assert(FC.Execution.IsBusy() and nativePresses == pressed, "unready native source must keep waiting")
    return job
end

do (function()
    local earlier = accept(986, 197, 1, "earlier-other-ready-task")
    recipe(986, 197)
    local lateProvider = beginSwitch(987)
    local readyJob, readyTask
    local emit = FC.Emit
    function FC:Emit(signal, ...)
        if signal == "PROFESSION_SWITCH_READY" then readyJob, readyTask = ... end
        return emit(self, signal, ...)
    end
    observedProfession = 185
    FC.Execution.InventoryChanged({reliable = true}, {regions = {professions = true}})
    advance(0)
    assert(FC.Execution.IsBusy() and nativePresses == 0 and not readyJob,
        "a different ready profession must not settle the switch")
    observedProfession, observedSource = 197, 2
    FC.Execution.InventoryChanged({reliable = true}, {regions = {professions = true}})
    advance(0)
    FC.Emit = emit
    assert(not FC.Execution.IsBusy() and nativePresses == 0 and readyJob == lateProvider
        and readyTask == lateProvider.tasks[1], "late exact readiness reports the accepted job and step without crafting")
    assert(FC.Execution.GetReadyRestockCraft() == readyTask and not FC.Execution.GetRestockProfession())
    assert(FC.Execution.ProcessClick() and lateProvider.status == "complete" and nativePresses == 1
        and earlier.status == "queued", "the next general Process keeps the target even with earlier work in the new profession")
    assert(FC.Queue.Cancel(earlier.id))
end)() end

local nextClick = beginSwitch(988)
observedProfession, observedSource = 197, 3
assert(FC.Execution.ProcessNext(nextClick) and nextClick.status == "complete" and nativePresses == 2,
    "a fresh user click can consume late exact readiness without another switch")

local timeoutCheck = beginSwitch(989)
observedProfession, observedSource = 197, 4
advance(8)
assert(not FC.Execution.IsBusy() and FC.Execution.message == FC.L.execSwitched
    and nativePresses == 2 and timeoutCheck.status == "queued" and switchRequests == 3,
    "the watchdog checks the exact ready profession before declaring a timeout and never creates an item")

do
    observedProfession = nil
    local synchronous = accept(9999, 197, 1, "synchronous-profession-reveal")
    recipe(9999, 197)
    local asynchronousSwitch = FC.Clients.SwitchProfession
    FC.Clients.SwitchProfession = function(id)
        assert(id == 197)
        observedProfession, observedSource = id, 5
        return true
    end
    local result, reason = FC.Execution.ProcessNext(synchronous)
    assert(not result and reason == FC.L.execSwitched and not FC.Execution.IsBusy()
        and nativePresses == 2 and synchronous.status == "queued"
        and FC.Execution.GetReadyRestockCraft(synchronous) == synchronous.tasks[1],
        "a synchronous reveal without a native event re-arms the craft immediately without submitting it")
    FC.Clients.SwitchProfession = asynchronousSwitch
end

assert(FC.Queue.Initialize({}))
local clearedRunning = accept(990, 197, 2, "clear-native-batch")
local clearedRecipe = recipe(990, 197)
local clearedOutput = clearedRecipe.outputItemID
FC.Clients.Craft = function(task, _, batch, beforeClick)
    assert(task == clearedRunning.tasks[1] and batch == 2 and beforeClick(batch))
    nativePresses = nativePresses + 1
    event("TRADE_SKILL_CRAFT_BEGIN", task.recipeId)
    return true, nil, batch
end
assert(FC.Execution.ProcessNext(clearedRunning))
assert(FC.Queue.Clear() and FC.Queue.IsClearing(clearedRunning) and FC.Execution.IsBusy())
output[clearedOutput] = 2
event("TRADE_SKILL_ITEM_CRAFTED_RESULT", {itemID = clearedOutput, quantity = 2, operationID = 990})
event("UPDATE_TRADESKILL_CAST_STOPPED", false)
advance(3)
local clearedTask = clearedRunning.tasks[1]
assert(clearedRunning.status == "cancelled" and clearedTask.completedExecutions == 1
    and clearedTask.remainingExecutions == 1 and clearedTask.evidence.matchedExecutions == 1
    and not FC.Execution.IsBusy() and nativePresses == 3,
    "Clear must let the issued result settle before cancelling the unstarted remainder")

local clearedUnknown = accept(995, 197, 1, "clear-unconfirmed-batch")
recipe(995, 197)
FC.Clients.Craft = function(_, _, batch, beforeClick)
    assert(batch == 1 and beforeClick(batch))
    nativePresses = nativePresses + 1
    return true, nil, batch
end
assert(FC.Execution.ProcessNext(clearedUnknown) and FC.Queue.Clear())
advance(180)
assert(clearedUnknown.status == "running" and FC.Execution.IsBusy(),
    "a pending Clear cannot discard the submission merely because a clock elapsed")
event("TRADE_SKILL_CLOSE")
assert(clearedUnknown.status == "cancelled" and clearedUnknown.tasks[1].status == "uncertain"
    and clearedUnknown.tasks[1].evidence and not FC.Execution.IsBusy() and nativePresses == 4,
    "closing the native source releases the hidden batch and retains its unconfirmed evidence")

local silkPack = recipe(6693, 197)
silkPack.outputItemID, silkPack.yield = 5764, 1
FC.InventoryAdapter.GetRevision = function() return "bags:silk-pack:" .. tostring(output[5764] or 0) end
FC.Clients.Craft = function(task, _, batch, beforeClick)
    assert(task.recipeId == silkPack.recipeID and batch == 1 and beforeClick(batch))
    return true, nil, batch
end
output[5764] = 0
local packJob = queueRecipe(silkPack)
assert(FC.Execution.ProcessNext(packJob))
event("UNIT_SPELLCAST_SUCCEEDED", "player", "green-silk-pack-1", 6693)
assert(packJob.status == "running" and packJob.tasks[1].evidence.exactPlayerCastCount == 1
    and not packJob.tasks[1].evidence.sawCraftEvent, "an exact cast needs a carried result")
output[5764] = 1
event("BAG_UPDATE_DELAYED")
assert(packJob.status == "complete" and packJob.tasks[1].completedExecutions == 1
    and packJob.tasks[1].evidence.confirmedByExactCasts == 1 and not FC.Execution.IsBusy(),
    "an exact Green Silk Pack cast and carried output must complete without any profession craft events")

local secondPack = queueRecipe(silkPack)
assert(FC.Execution.ProcessNext(secondPack))
output[5764] = 2
event("BAG_UPDATE_DELAYED")
event("UNIT_SPELLCAST_SUCCEEDED", "player", "green-silk-pack-1", 6693)
event("UNIT_SPELLCAST_SUCCEEDED", "party1", "green-silk-pack-2", 6693)
event("UNIT_SPELLCAST_SUCCEEDED", "player", "wrong-spell-near-green-silk-pack", 12079)
assert(secondPack.status == "running" and not secondPack.tasks[1].evidence.exactPlayerCastCount,
    "bag gains, duplicated casts and successes for another player or spell must not settle a new batch")
event("UNIT_SPELLCAST_SUCCEEDED", "player", "green-silk-pack-2", 6693)
assert(secondPack.status == "complete" and secondPack.tasks[1].completedExecutions == 1
    and not FC.Execution.IsBusy(), "an exact new success can arrive after the matching bag update")

local conflictingPack = queueRecipe(silkPack)
assert(FC.Execution.ProcessNext(conflictingPack))
event("TRADE_SKILL_CRAFT_BEGIN", 12079)
event("UNIT_SPELLCAST_SUCCEEDED", "player", "green-silk-pack-3", 6693)
output[5764] = 3
event("BAG_UPDATE_DELAYED")
advance(180)
assert(conflictingPack.tasks[1].completedExecutions == 0)
event("TRADE_SKILL_CLOSE")
assert(conflictingPack.status == "uncertain" and conflictingPack.tasks[1].completedExecutions == 0,
    "a different observed native recipe begin invalidates the player-cast fallback")
assert(FC.Queue.Cancel(conflictingPack.id))

local changedSourcePack = queueRecipe(silkPack)
assert(FC.Execution.ProcessNext(changedSourcePack))
event("UNIT_SPELLCAST_SUCCEEDED", "player", "green-silk-pack-4", 6693)
observedSource = observedSource + 1
output[5764] = 4
event("BAG_UPDATE_DELAYED")
advance(180)
assert(changedSourcePack.tasks[1].completedExecutions == 0)
event("TRADE_SKILL_DATA_SOURCE_CHANGED")
assert(changedSourcePack.status == "uncertain" and changedSourcePack.tasks[1].completedExecutions == 0
    and not changedSourcePack.tasks[1].evidence.carriedResult,
    "a cast cannot be corroborated from a different profession data source")
assert(not FC.Execution.ReconcileUncertain(changedSourcePack) and FC.Queue.Cancel(changedSourcePack.id))

local nativeRecipe = recipe(10002, 197)
local otherRestockJob = queueRecipe(recipe(10003, 171))
FC.InventoryAdapter.GetRevision = function() return "bags:handoff:" .. tostring(output[nativeRecipe.outputItemID] or 0) end
local native = {}
FC.Clients.Craft = function(task, _, batch, onAttempt, onEntry)
    assert(task.recipeId == nativeRecipe.id and batch == 1)
    native.attempt, native.entry = onAttempt, onEntry
    return true, nil, "native_click", batch
end
local restockProfessionBefore = assert(FC.Execution.GetRestockProfession())
local nativeJob = queueRecipe(nativeRecipe)
assert(restockProfessionBefore.jobId == otherRestockJob.id
    and FC.Execution.GetReadyRestockCraft(nativeJob) == nativeJob.tasks[1] and not FC.Execution.GetRestockProfession(),
    "the Restock opener must not override a ready craft in the current profession")
local staged, _, pending, stage = FC.Execution.ProcessNext(nativeJob)
assert(staged and stage == "native_click" and pending == nativeJob and FC.Execution.HasNativeCraftPending()
    and not FC.Execution.IsBusy() and not nativeJob.tasks[1].evidence,
    "handing off to Blizzard keeps the exact unpressed order pending")
local nativeSelection = assert(FC.Execution.GetNativeCraftRecipe())
assert(nativeSelection.recipeID == nativeRecipe.id and nativeSelection.professionId == 197 and nativeSelection.batch == 1
    and nativeSelection == FC.Execution.GetNativeCraftRecipe() and not FC.Execution.GetReadyRestockCraft(nativeJob)
    and not FC.Execution.GetRestockProfession() and not FC.Execution.OpenRestockProfession(restockProfessionBefore),
    "the armed batch stays exact and temporarily replaces both Restock prompts")
do
    local exact, quantity, candidate, direct, prepare = FC.Execution.GetReadyRestockCraft(nil, true)
    assert(exact == nativeJob.tasks[1] and quantity == 1 and candidate == nativeJob and not direct and prepare
        and not FC.Execution.GetReadyRestockCraft(otherRestockJob, true),
        "a hidden or out-of-date native form can reoffer its own armed task for preparation")
    local inputs = exact.inputs
    exact.inputs = {{itemID = 90188, quantity = 1}}
    assert(not FC.Execution.GetReadyRestockCraft(nil, true), "retry still requires every input in bags")
    exact.inputs = inputs
    local recasts = C_TradeSkillUI.GetRemainingRecasts
    C_TradeSkillUI.GetRemainingRecasts = function() return 1 end
    assert(not FC.Execution.GetReadyRestockCraft(nil, true), "active native work prevents rearming")
    C_TradeSkillUI.GetRemainingRecasts = recasts
    local oldAttempt = native.attempt
    local ok, _, job, phase = FC.Execution.ProcessNext(candidate, exact, true)
    assert(ok and job == nativeJob and phase == "native_click"
        and not oldAttempt(1) and not exact.evidence and nativeJob.status == "queued",
        "an explicit retry replaces the armed preparation without creating a craft or receipt")
end
observedSource = observedSource + 1
assert(not FC.Execution.GetNativeCraftRecipe(), "a different native source cannot read the armed batch")
observedSource = observedSource - 1
local abandonedAttempt = native.attempt
local refreshes, emit = 0, FC.Emit
function FC:Emit(signal, ...)
    if signal == "EXECUTION_CHANGED" then refreshes = refreshes + 1 end
    return emit(self, signal, ...)
end
FC.Execution.CancelNativeCraft()
FC.Emit = emit
assert(not abandonedAttempt(1) and not nativeJob.tasks[1].evidence and not FC.Execution.GetNativeCraftRecipe()
    and FC.Execution.GetReadyRestockCraft(nativeJob) == nativeJob.tasks[1]
    and not FC.Execution.GetRestockProfession() and refreshes == 1,
    "cancelling the handoff leaves no live action and restores the ready craft before the remote opener")
assert(FC.Queue.Cancel(otherRestockJob.id))

assert(FC.Execution.ProcessNext(nativeJob))
native.entry()
assert(not FC.Execution.GetReadyRestockCraft(nil, true), "a real native entry owns the handoff")
event("TRADE_SKILL_CRAFT_BEGIN", nativeRecipe.id)
event("TRADE_SKILL_ITEM_CRAFTED_RESULT", {itemID = nativeRecipe.outputItemID, quantity = 2})
assert(not native.attempt(nil, FC.L.clients.staleReagents) and not FC.Execution.HasNativeCraftPending()
    and not nativeJob.tasks[1].evidence, "early results from a mismatched native press leave the queued order untouched")
assert(FC.Execution.ProcessNext(nativeJob) and native.attempt(1))
assert(not FC.Execution.HasNativeCraftPending() and FC.Execution.IsBusy()
    and nativeJob.tasks[1].evidence.batch == 1 and nativeJob.tasks[1].status == "in_flight",
    "a matching native press starts observing the same saved task")
event("UNIT_SPELLCAST_SUCCEEDED", "player", "native-handoff-1", nativeRecipe.id)
output[nativeRecipe.outputItemID] = 2
event("BAG_UPDATE_DELAYED")
assert(nativeJob.status == "complete" and not FC.Execution.IsBusy() and not native.attempt(1),
    "only the exact native cast and carried result can complete the handed-off task once")

local unobserved = accept(nativeRecipe.id, 197, 2, "native-handoff-capped")
FC.Clients.Craft = function(task, _, batch, onAttempt)
    assert(task.recipeId == nativeRecipe.id and batch == 2)
    native.attempt = onAttempt
    return true, nil, "native_click", 1
end
assert(FC.Execution.ProcessNext(unobserved) and FC.Execution.GetNativeCraftRecipe().batch == 1,
    "Restock exposes the authorized native count even when the queued remainder is larger")
advance(180)
assert(FC.Execution.HasNativeCraftPending() and not unobserved.tasks[1].evidence and unobserved.status == "queued",
    "waiting for a native Create click does not expire or submit the queued order")
FC.Execution.CancelNativeCraft()
assert(not FC.Execution.HasNativeCraftPending() and not native.attempt(1) and not unobserved.tasks[1].evidence
    and unobserved.status == "queued", "cancelling the native handoff leaves the unsubmitted queue intact")

assert(FC.Queue.Initialize({}))
local mageweaveBag = recipe(12079, 197)
mageweaveBag.name, mageweaveBag.outputItemID, mageweaveBag.yield = "Red Mageweave Bag", 10051, 1
mageweaveBag.yieldMax, mageweaveBag.characterKey, mageweaveBag.completeness = 1, FC.state.characterKey, "complete"
mageweaveBag.reagents = {{itemID = 2604, quantity = 2}, {itemID = 4339, quantity = 5}, {itemID = 8343, quantity = 2}}
local mageweaveBolt = recipe(3865, 197)
mageweaveBolt.name, mageweaveBolt.outputItemID, mageweaveBolt.yield = "Bolt of Mageweave", 4339, 1
mageweaveBolt.yieldMax, mageweaveBolt.characterKey, mageweaveBolt.completeness = 1, FC.state.characterKey, "complete"
mageweaveBolt.reagents = {{itemID = 4338, quantity = 5}}
local mageweaveCatalog = {recipesById = recipes, byOutput = {[4339] = {3865}, [10051] = {12079}}, revision = 8}
FC.Catalog.Snapshot = function() return mageweaveCatalog end
output[4338], output[4339], output[2604], output[8343], output[10051] = 125, 0, 10, 10, 0
FC.InventoryAdapter.GetRevision = function() return "bags:mageweave:" .. tostring(output[4339]) end
local preparations = {}
FC.Clients.Resolve = function(task)
    assert(task.recipeId == mageweaveBolt.id or output[4339] == 25,
        "the final recipe cannot be resolved for action before making its 25 bolts")
    return {kind = "forever", recipeID = task.recipeId, maxYield = 1}
end
FC.Clients.Craft = function(task, _, batch, onAttempt, onEntry)
    preparations[#preparations + 1] = {task = task, batch = batch, press = onAttempt, entry = onEntry}
    return true, nil, "native_click", batch
end
local bagsOnlyOrder = assert(FC.Execution.QueueAllSelected(mageweaveBag.id))
assert(#preparations == 0 and bagsOnlyOrder.summary.executions == 5 and #bagsOnlyOrder.tasks == 2
    and #bagsOnlyOrder.requirements == 0 and FC.Queue.Cancel(bagsOnlyOrder.id),
    "Queue All finds the same bag-funded route without preparing a native action")

do
    local order = assert(FC.Execution.QueueAllSelected(mageweaveBag.id))
    output[2604] = 0
    assert(not FC.Execution.GetReadyRestockCraft(order) and not FC.Execution.ProcessNext(order, order.tasks[1]),
        "carried materials for 25 bolts do not qualify a five-bag plan with missing dye")
    assert(#preparations == 0 and order.status == "queued")
    output[2604] = 10
    assert(FC.Execution.GetReadyRestockCraft(order) == order.tasks[1] and output[4339] == 0,
        "the exact pending producer supplies the future bag inputs without requiring its bolts before crafting")
    assert(FC.Queue.Cancel(order.id))
end

local queuedAndReady, _, bagOrder, nativePhase = FC.Execution.CraftSelected(mageweaveBag.id, true)
assert(queuedAndReady and nativePhase == "native_click" and bagOrder.status == "queued"
    and bagOrder.summary.requested == 5 and #bagOrder.requirements == 0 and not bagOrder.goal.autoBuyVendor
    and bagOrder.reservations["4338"] == 125 and bagOrder.reservations["2604"] == 10 and bagOrder.reservations["8343"] == 10,
    "Create All accepts the full five-bag chain from carried stock before a native action")
local boltStep, bagStep = bagOrder.tasks[1], bagOrder.tasks[2]
assert(boltStep.recipeId == 3865 and boltStep.executions == 25 and bagStep.recipeId == 12079 and bagStep.executions == 5
    and preparations[1].task == boltStep and preparations[1].batch == 25,
    "the exact 25-bolt prerequisite is handed off before the five final bags")
do
    local boltPress = preparations[1]
    boltPress.entry()
    event("TRADE_SKILL_CRAFT_BEGIN", boltStep.recipeId)
    event("TRADE_SKILL_ITEM_CRAFTED_RESULT", {itemID = 10051, quantity = 25, operationID = 12079})
    event("TRADE_SKILL_ITEM_CRAFTED_RESULT", {itemID = 4339, quantity = 25, operationID = 3865})
    assert(boltStep.status == "pending" and not boltStep.evidence,
        "early observations alone must not start or credit the pending task")
    assert(boltPress.press(25) and boltStep.evidence.matchedExecutions == 25 and boltStep.status == "in_flight",
        "the exact native post-hook preserves synchronous observations and waits for carried output")
end
output[4338], output[4339] = 0, 25
event("BAG_UPDATE_DELAYED")
assert(boltStep.status == "complete" and bagStep.status == "pending" and #preparations == 1,
    "the completed prerequisite records its carried output without auto-starting the final craft")
local readyForBags, _, _, bagPhase = FC.Execution.ProcessNext(bagOrder)
assert(readyForBags and bagPhase == "native_click" and preparations[2].task == bagStep and preparations[2].batch == 5,
    "the next explicit Process prepares the five-bag craft using its reserved bolts")
do
    local bagPress = preparations[2]
    bagPress.entry()
    event("TRADE_SKILL_CRAFT_BEGIN", bagStep.recipeId)
    event("TRADE_SKILL_ITEM_CRAFTED_RESULT", {itemID = 10051, quantity = 5, operationID = 12079})
    advance(0)
    assert(bagPress.press(5) and not bagStep.evidence.matchedExecutions,
        "an early result cannot be credited to a later native invocation")
end
event("TRADE_SKILL_CRAFT_BEGIN", bagStep.recipeId)
event("TRADE_SKILL_ITEM_CRAFTED_RESULT", {itemID = 10051, quantity = 5, operationID = 12079})
assert(bagStep.evidence.matchedExecutions == 5 and bagOrder.status == "running")
output[10051] = 5
event("BAG_UPDATE_DELAYED")
assert(bagOrder.status == "complete" and bagStep.completedExecutions == 5,
    "a fresh matching begin and carried bags settle the final five crafts")

do
    local function verifyGroupedCrafts(finishedBolts)
        assert(FC.Queue.Initialize({}))
        preparations = {}
        local bag = recipe(6693, 197)
        bag.name, bag.outputItemID, bag.yield, bag.yieldMax = "Green Silk Pack", 5764, 1, 1
        bag.characterKey, bag.completeness = FC.state.characterKey, "complete"
        bag.reagents = {{itemID = 4305, quantity = 5}, {itemID = 4234, quantity = 3},
            {itemID = 2321, quantity = 3}, {itemID = 2605, quantity = 1}}
        local bolt = recipe(3839, 197)
        bolt.name, bolt.outputItemID, bolt.yield, bolt.yieldMax = "Bolt of Silk Cloth", 4305, 1, 1
        bolt.characterKey, bolt.completeness = FC.state.characterKey, "complete"
        bolt.reagents = {{itemID = 4306, quantity = 4}}
        FC.Catalog.Snapshot = function()
            return {recipesById = recipes, byOutput = {[4305] = {bolt.id}, [5764] = {bag.id}}, revision = 9}
        end
        FC.Clients.Resolve = function(task)
            if task.recipeId == bag.id and output[4305] < 5 then return nil, FC.L.execMissingMaterials end
            return {kind = "forever", recipeID = task.recipeId, maxYield = 1}
        end
        output[4306], output[4305], output[4234], output[2321], output[2605], output[5764] = 60, 0, 9, 9, 3, 0
        local orders = {}
        for index = 1, 3 do
            local function preview()
                return FC.Logistics.Preview({recipeId = bag.id, quantity = 1, bagsOnly = true})
            end
            orders[index] = assert(FC.Queue.Accept(preview(), preview))
            assert(orders[index].tasks[1].executions == 5)
        end

        if finishedBolts > 0 then
            local first = orders[1]
            assert(FC.Queue.Begin(first, first.tasks[1], {batch = finishedBolts, beforeOutput = 0}))
            FC.Queue.CraftEvent(first, first.tasks[1], finishedBolts, finishedBolts)
            output[4306], output[4305] = output[4306] - finishedBolts * 4, finishedBolts
            assert(FC.Queue.Reconcile(first, first.tasks[1], finishedBolts))
        end
        local remaining = 15 - finishedBolts
        output[4306] = remaining * 4 - 1
        local _, short = FC.Execution.GetReadyRestockCraft()
        assert(#FC.Queue.GetJobs() == 3 and (finishedBolts == 0 and not short
            or finishedBolts > 0 and short and short < remaining),
            "missing cloth blocks unfinished orders while a fully supplied separate order remains eligible")
        output[4306] = remaining * 4
        local ready, batch = FC.Execution.GetReadyRestockCraft()
        assert(ready.recipeId == bolt.id and batch == remaining and #FC.Queue.GetJobs() == 3 and #preparations == 0,
            "the Restock reminder advertises the grouped prerequisite without mutating the queue")

        local ok, _, combined = FC.Execution.ProcessClick(orders[1])
        assert(ok and combined.summary.requested == 3 and preparations[1].batch == remaining
            and preparations[1].task.recipeId == bolt.id and #preparations == 1
            and combined.reservations["4306"] == remaining * 4,
            "Process prepares all remaining bolts first, even when the oldest bag already has enough bolts")
        for _, order in ipairs(orders) do
            assert(order.status == "replaced" and order.replacement == combined.id and not next(order.reservations))
        end
        assert(preparations[1].press(remaining))
        event("TRADE_SKILL_CRAFT_BEGIN", bolt.id)
        event("TRADE_SKILL_ITEM_CRAFTED_RESULT", {itemID = 4305, quantity = remaining, operationID = 3839})
        output[4306], output[4305] = 0, 15
        event("BAG_UPDATE_DELAYED")
        assert(combined.tasks[1].status == "complete" and combined.tasks[2].status == "pending"
            and #preparations == 1, "the final recipe waits for a separate press even with all fifteen bolts ready")

        assert(FC.Execution.ProcessClick(combined))
        assert(preparations[2].task.recipeId == bag.id and preparations[2].batch == 3 and preparations[2].press(3))
        event("TRADE_SKILL_CRAFT_BEGIN", bag.id)
        event("TRADE_SKILL_ITEM_CRAFTED_RESULT", {itemID = 5764, quantity = 3, operationID = 6693})
        output[4305], output[4234], output[2321], output[2605], output[5764] = 0, 0, 0, 0, 3
        event("BAG_UPDATE_DELAYED")
        assert(combined.status == "complete" and combined.tasks[2].completedExecutions == 3)
    end
    verifyGroupedCrafts(0)
    verifyGroupedCrafts(5)
end

local blockedSave = {}
assert(FC.Queue.Initialize(blockedSave))
preparations = {}
FC.Catalog.Snapshot = function() return mageweaveCatalog end
FC.Clients.Resolve = function(task)
    return {kind = "forever", recipeID = task.recipeId, maxYield = 1}
end
output[4338], output[4339], output[2604], output[8343] = 125, 0, 10, 10
local blockedOrder = assert(FC.Execution.QueueAllSelected(mageweaveBag.id))
local blockedBolt = blockedOrder.tasks[1]
local currentVersion = FC.version
FC.version = "0.2.38-dev"
assert(FC.Queue.Begin(blockedOrder, blockedBolt, {batch = 25, beforeOutput = 0, maxYield = 1,
    recipeId = 3865, professionId = 197, sessionGeneration = 4, sourceCounter = 137,
    inventoryRevision = "builtin:2:13:33"}))
local blockedEvidence = blockedBolt.evidence
local originalRevision = blockedOrder.planRevision
FC.Queue.MarkUncertain(blockedOrder, blockedBolt, FC.L.execBlockedByClient)
FC.version = currentVersion
assert(FC.Queue.Initialize(blockedSave))
assert(FC.Execution.CanRetryBlockedCraft(blockedOrder) and not FC.Execution.ReconcileUncertain(blockedOrder)
    and blockedOrder.status == "uncertain", "Review does not replay the historical attempt")

for _, field in ipairs({"matchedExecutions", "exactPlayerCastCount", "reportedOutput", "afterOutput", "carriedResult"}) do
    blockedEvidence[field] = 1
    assert(not FC.Execution.CanRetryBlockedCraft(blockedOrder), "reject historical evidence of " .. field)
    blockedEvidence[field] = nil
end
mageweaveBolt.revision = mageweaveBolt.revision + 1
assert(not FC.Execution.CanRetryBlockedCraft(blockedOrder))
mageweaveBolt.revision = mageweaveBolt.revision - 1

local getInventoryStatus = FC.InventoryAdapter.GetStatus
FC.InventoryAdapter.GetStatus = function() return {reliable = false} end
assert(FC.Execution.CanRetryBlockedCraft(blockedOrder) and not FC.Execution.RetryBlockedCraft(blockedOrder),
    "metadata controls availability while the action requires reliable carried stock")
FC.InventoryAdapter.GetStatus = getInventoryStatus
output[4339] = 1
assert(not FC.Execution.RetryBlockedCraft(blockedOrder), "changed output cannot qualify a retry")
output[4339], output[4338] = 0, 130
local competingWork = assert(FC.Execution.QueueAllSelected(mageweaveBolt.id))
assert(competingWork.reservations["4338"] == 5)
output[4338] = 125
assert(not FC.Execution.RetryBlockedCraft(blockedOrder) and FC.Queue.Cancel(competingWork.id)
    and #preparations == 0, "the whole original batch must be available after competing reservations")

assert(FC.Execution.RetryBlockedCraft(blockedOrder) and blockedOrder.status == "queued"
    and blockedBolt.status == "pending" and blockedBolt.remainingExecutions == 25 and not blockedBolt.evidence
    and blockedBolt.retriedAttempt.evidence == blockedEvidence and blockedOrder.planRevision == originalRevision
    and blockedOrder.reservations["4338"] == 125 and #preparations == 0
    and not FC.Execution.CanRetryBlockedCraft(blockedOrder), "Retry reopens the original task and retains its evidence once")
assert(FC.Queue.Initialize(blockedSave))
local retriedReady, _, retriedJob, retriedPhase = FC.Execution.ProcessNext(blockedOrder)
assert(retriedReady and retriedJob == blockedOrder and retriedPhase == "native_click"
    and preparations[1].task == blockedBolt and preparations[1].batch == 25 and not blockedBolt.evidence
    and blockedBolt.retriedAttempt.evidence == blockedEvidence, "only a separate Process prepares the original 25-bolt retry")
FC.Execution.CancelNativeCraft()

do (function()
    local row = recipe(1991, open)
    local directCalls, nativeCalls = 0, 0
    local recasts, casting, channel, mode = 0, nil, nil, "complete"
    FC.name = "FluxLogistics"
    C_TradeSkillUI = {GetRemainingRecasts = function() return recasts end}
    UnitCastingInfo = function(unit) assert(unit == "player"); return casting end
    UnitChannelInfo = function(unit) assert(unit == "player"); return channel end
    FC.Clients.Resolve = function(task)
        return {kind = "forever", recipeID = task.recipeId, maxYield = 2, maxExecutions = 2,
            choice = task.inputs[1] and {{itemID = task.inputs[1].itemID, quantity = 1}} or nil}
    end
    FC.Clients.CanDispatchQueuedCraft = function(live) return live.recipeID == row.id end
    FC.Clients.Craft = function(_, _, batch)
        nativeCalls = nativeCalls + 1
        return true, nil, "native_click", batch
    end
    FC.Clients.DispatchQueuedCraft = function(task, live, batch, beforeClick)
        directCalls = directCalls + 1
        assert(task.recipeId == row.id and live.recipeID == row.id and batch == 2)
        if mode == "unsupported" then return false, "not supported", "unsupported" end
        if mode == "changed-before-submit" then
            recasts = 1
            assert(not beforeClick(1), "a craft appearing during preflight blocks journaling and dispatch")
            return false, FC.L.execBusy, "not_submitted"
        end
        local count = mode == "pending-partial" and 2 or 1
        local beforeOutput = output[task.outputItemID] or 0
        assert(beforeClick(count) and task.status == "in_flight" and task.evidence.batch == count
            and task.evidence.dispatch == "process"
            and task.evidence.beforeOutput == beforeOutput, "the authorized direct batch was journaled before the call")
        if mode == "not-submitted" then return false, "stale native state", "not_submitted" end
        if mode == "attempted" then return false, "the native call rejected the craft", "attempted" end
        if mode == "raised" then error("the native call raised after entry") end
        if mode == "pending" or mode == "pending-partial" then return true, nil, count end
        if mode == "denied-after-begin" then event("TRADE_SKILL_CRAFT_BEGIN", row.id) end
        if mode == "denied" or mode == "denied-after-begin" then
            event("ADDON_ACTION_BLOCKED", FC.name, "C_TradeSkillUI.CraftRecipe()")
            return true, nil, 1
        end
        event("TRADE_SKILL_CRAFT_BEGIN", row.id)
        event("TRADE_SKILL_ITEM_CRAFTED_RESULT", {itemID = task.outputItemID, quantity = 2, operationID = 1991})
        output[task.outputItemID] = 2
        event("BAG_UPDATE_DELAYED")
        return true, nil, 1
    end
    local function freshJob()
        assert(FC.Queue.Initialize({}))
        output[row.outputItemID] = 0
        return accept(row.id, open, 3, "direct-process")
    end

    local directJob = freshJob()
    local task = directJob.tasks[1]
    local readyTask, batch, readyJob, canDirect = FC.Execution.GetReadyRestockCraft(directJob)
    assert(readyTask == task and batch == 2 and readyJob == directJob and canDirect and directCalls == 0)
    local _, _, _, phase = FC.Execution.ProcessNext(directJob, task)
    assert(phase == "native_click" and nativeCalls == 1 and directCalls == 0 and not task.evidence,
        "an internal continuation can prepare a native handoff without direct dispatch")
    FC.Execution.CancelNativeCraft()
    local ok, _, returned
    ok, _, returned, phase = FC.Execution.ProcessClick(directJob, task)
    assert(ok and returned == directJob and phase == "dispatched" and directCalls == 1 and nativeCalls == 1
        and task.completedExecutions == 1 and task.remainingExecutions == 2 and directJob.status == "queued",
        "one explicit click dispatches one bounded batch and reconciles the carried result once")

    directJob, mode = freshJob(), "denied"
    task = directJob.tasks[1]
    ok, _, _, phase = FC.Execution.ProcessClick(directJob, task)
    assert(not ok and phase == "direct_denied" and task.status == "pending" and not task.evidence
        and nativeCalls == 1 and directCalls == 2, "proven denial does not start a second action on that click")
    _, _, _, canDirect = FC.Execution.GetReadyRestockCraft(directJob)
    assert(canDirect == false and not FC.Execution.IsBusy())
    ok, _, _, phase = FC.Execution.ProcessClick(directJob, task)
    assert(ok and phase == "native_click" and nativeCalls == 2 and directCalls == 2,
        "a fresh click selects the native fallback after a proven exact denial")
    FC.Execution.CancelNativeCraft()

    for _, result in ipairs({"attempted", "raised", "denied-after-begin"}) do
        directJob, mode = freshJob(), result
        local calls = directCalls
        assert(not FC.Execution.ProcessClick(directJob) and directJob.status == "uncertain"
            and directJob.tasks[1].evidence and not FC.Execution.ProcessClick(directJob)
            and directCalls == calls + 1 and nativeCalls == 2,
            "an attempted or ambiguous action requires review before another dispatch: " .. result)
    end

    directJob, mode = freshJob(), "pending"
    assert(FC.Execution.ProcessClick(directJob) and directJob.status == "running")
    event("ADDON_ACTION_FORBIDDEN", FC.name, "BuyMerchantItem()")
    event("ADDON_ACTION_FORBIDDEN", "OtherAddon", "CraftRecipe()")
    assert(directJob.status == "running", "a different protected action or addon cannot release the craft journal")
    event("ADDON_ACTION_FORBIDDEN", FC.name, "CraftRecipe()")
    assert(directJob.status == "queued" and not directJob.tasks[1].evidence and nativeCalls == 2,
        "a matching delayed denial without evidence releases the exact original task")

    directJob, mode = freshJob(), "not-submitted"
    ok = FC.Execution.ProcessClick(directJob)
    assert(not ok and directJob.status == "queued" and not directJob.tasks[1].evidence and nativeCalls == 2,
        "a proven pre-call rejection leaves the queue pending without a second action")

    directJob, mode = freshJob(), "unsupported"
    ok, _, _, phase = FC.Execution.ProcessClick(directJob)
    assert(ok and phase == "native_click" and nativeCalls == 3 and not directJob.tasks[1].evidence,
        "before any journal or action an unsupported dispatch can prepare the native fallback")
    FC.Execution.CancelNativeCraft()

    directJob, mode = freshJob(), "changed-before-submit"
    local calls = directCalls
    recasts = 1
    assert(not FC.Execution.GetReadyRestockCraft(directJob) and not FC.Execution.ProcessClick(directJob))
    recasts, casting = 0, "Another craft"
    assert(not FC.Execution.ProcessClick(directJob))
    casting, channel = nil, "Another channel"
    assert(not FC.Execution.ProcessClick(directJob))
    channel, recasts = nil, nil
    assert(not FC.Execution.ProcessClick(directJob) and directCalls == calls)
    recasts = 0
    assert(not FC.Execution.ProcessClick(directJob) and directCalls == calls + 1 and nativeCalls == 3
        and directJob.status == "queued" and not directJob.tasks[1].evidence,
        "another cast, channel, recast or unavailable native state cannot dispatch queued work")

    recasts = 0
    FC.InventoryAdapter.GetStatus = function() return {reliable = true, source = "builtin", sourceGeneration = 1} end
    for index, consumed in ipairs({true, false}) do
        directJob, mode = freshJob(), "pending-partial"
        task = directJob.tasks[1]
        task.inputs = {{itemID = 7000, quantity = 3}}
        output[7000] = 3
        assert(FC.Execution.ProcessClick(directJob) and task.evidence.batch == 2)
        local guid = "direct-partial-" .. index
        event("UNIT_SPELLCAST_SUCCEEDED", "player", guid, row.id)
        event("UNIT_SPELLCAST_SUCCEEDED", "player", guid, row.id)
        assert(FC.Queue.VisibleCompletedExecutions(task) == 0, "a cast alone leaves the visible quantity unchanged")
        output[task.outputItemID] = 2
        if consumed then output[7000] = 2 end
        event("BAG_UPDATE_DELAYED")
        assert(task.completedExecutions == 0 and task.status == "in_flight"
            and FC.Queue.VisibleCompletedExecutions(task) == (consumed and 1 or 0),
            "exact cast and matching output and inputs update the row before the batch ends")
        event("UPDATE_TRADESKILL_CAST_STOPPED", false)
        advance(2)
        if consumed then
            assert(task.completedExecutions == 1 and task.remainingExecutions == 2 and directJob.status == "queued"
                and FC.Queue.VisibleCompletedExecutions(task) == 1,
                "the terminal cast credits one exact deterministic result and its consumed carried inputs")
        else
            assert(task.completedExecutions == 0 and directJob.status == "running",
                "without corresponding consumed inputs a partial cast cannot release the journal")
            event("TRADE_SKILL_CLOSE")
            assert(directJob.status == "uncertain")
        end
    end

    local function startInterruptibleBatch(guid, sawCraftBegin)
        local job = freshJob()
        local pending = job.tasks[1]
        pending.inputs = {{itemID = 7000, quantity = 3}}
        output[7000], mode = 3, "pending-partial"
        assert(FC.Execution.ProcessClick(job) and pending.evidence.batch == 2)
        if sawCraftBegin then event("TRADE_SKILL_CRAFT_BEGIN", row.id) end
        event("UNIT_SPELLCAST_SENT", "player", "", guid, row.id)
        event("UNIT_SPELLCAST_START", "player", guid, row.id)
        return job, pending
    end

    directJob, task = startInterruptibleBatch("interrupted-exact", true)
    local revision, pressed = directJob.planRevision, directCalls
    event("UNIT_SPELLCAST_INTERRUPTED", "player", "interrupted-exact", row.id)
    assert(directJob.status == "queued" and not FC.Execution.IsBusy(),
        "a witnessed first-cast interruption with unchanged stock reopens the order in the stop event")
    event("UPDATE_TRADESKILL_CAST_STOPPED", false)
    advance(3)
    assert(FC.Queue.GetJob(directJob.id) == directJob and directJob.planRevision == revision
        and directJob.status == "queued" and task.status == "pending" and task.completedExecutions == 0
        and task.remainingExecutions == 3 and directCalls == pressed and nativeCalls == 3,
        "an exact interrupted cast with unchanged stock returns the same job to Process without replay")
    assert(FC.Execution.ProcessClick(directJob, task) and directCalls == pressed + 1
        and task.evidence.batch == 2 and task.status == "in_flight", "a fresh click starts the same authorized batch")
    event("UNIT_SPELLCAST_START", "player", "interrupted-second-press", row.id)
    event("UNIT_SPELLCAST_INTERRUPTED", "player", "interrupted-second-press", row.id)
    event("UPDATE_TRADESKILL_CAST_STOPPED", false)
    assert(not FC.Execution.IsBusy())

    directJob, task = startInterruptibleBatch("interrupted-after-input-change", true)
    output[7000] = 2
    event("UNIT_SPELLCAST_INTERRUPTED", "player", "interrupted-after-input-change", row.id)
    event("UPDATE_TRADESKILL_CAST_STOPPED", false)
    advance(3)
    assert(directJob.status == "running" and task.completedExecutions == 0,
        "changed carried inputs do not prove an interrupted batch made nothing")
    event("TRADE_SKILL_CLOSE")
    assert(directJob.status == "uncertain")

    directJob, task = startInterruptibleBatch("interrupted-expected-guid", false)
    pressed = directCalls
    event("UNIT_SPELLCAST_INTERRUPTED", "player", "interrupted-different-guid", row.id)
    advance(180)
    assert(directJob.status == "running" and task.remainingExecutions == 3 and directCalls == pressed,
        "another cast's interruption cannot terminate the selected batch regardless of elapsed time")
    event("UNIT_SPELLCAST_INTERRUPTED", "player", "interrupted-expected-guid", row.id)
    event("UPDATE_TRADESKILL_CAST_STOPPED", false)
    assert(directJob.status == "queued" and task.remainingExecutions == 3 and directCalls == pressed,
        "the exact witnessed interruption reopens the unchanged batch without another submission")

    row.name, row.outputItemID, row.yield, row.yieldMax = "Green Silk Pack", 5764, 1, 1
    row.characterKey, row.completeness = FC.state.characterKey, "complete"
    row.reagents = {{itemID = 4305, quantity = 5}, {itemID = 4234, quantity = 3},
        {itemID = 2321, quantity = 3}, {itemID = 2605, quantity = 1}}
    FC.Clients.Resolve = function()
        return {kind = "forever", recipeID = row.id, maxYield = 1, choice = row.reagents}
    end
    local function startBagBatch()
        assert(FC.Queue.Initialize({}))
        output[5764], output[4305], output[4234], output[2321], output[2605] = 1, 10, 6, 6, 2
        local function preview()
            return FC.Logistics.Preview({recipeId = row.id, quantity = 2, bagsOnly = true})
        end
        local job = assert(FC.Queue.Accept(preview(), preview))
        mode = "pending-partial"
        assert(FC.Execution.ProcessClick(job))
        return job, job.tasks[1]
    end
    local function bagUpdate(made, carried)
        output[5764] = carried
        for _, reagent in ipairs(row.reagents) do output[reagent.itemID] = (2 - made) * reagent.quantity end
        event("BAG_UPDATE_DELAYED")
    end

    directJob, task = startBagBatch()
    bagUpdate(2, 3)
    assert(directJob.status == "complete" and task.completedExecutions == 2
        and task.evidence.confirmedByDirectStock == 2 and not FC.Execution.IsBusy(),
        "the full bag and reagent deltas settle a successful dispatch without spellcast or profession results")

    directJob, task = startBagBatch()
    bagUpdate(1, 2)
    assert(task.status == "in_flight" and FC.Queue.VisibleCompletedExecutions(task) == 1)
    event("UPDATE_TRADESKILL_CAST_STOPPED", false)
    advance(2)
    assert(directJob.status == "queued" and task.completedExecutions == 1 and task.remainingExecutions == 1,
        "after a verified partial craft only the outstanding bag remains")

    local originalGUID = UnitGUID
    UnitGUID = function(unit) assert(unit == "player"); return "fixture-player" end
    LOOT_ITEM_CREATED_SELF = "You |4make:makes;: %s."
    LOOT_ITEM_CREATED_SELF_MULTIPLE = "You make %2$d of %1$s."
    local link = "|cnIQ1:|Hitem:5764:0|h[Green Silk Pack]|h|r"
    local function loot(text, line, guid)
        event("CHAT_MSG_LOOT", text, "", "", "", "", "", 0, 0, "", 0, line, guid or "fixture-player")
    end
    directJob, task = startBagBatch()
    bagUpdate(2, 2)
    loot("You receive loot: " .. link .. ".", 1)
    loot("You make 2 of " .. link .. ".", 2, "other-player")
    loot("You make: " .. link .. ".", 3)
    loot("You make: " .. link .. ".", 3)
    assert(directJob.status == "running" and task.completedExecutions == 0,
        "ordinary loot, other players and duplicate chat lines cannot settle a craft")
    loot("You make: " .. link .. ".", 4)
    assert(directJob.status == "complete" and task.completedExecutions == 2
        and task.evidence.afterOutput == 2 and task.evidence.confirmedByCreatedOutput == 2,
        "two matching item-creation messages and the exact consumed reagents settle both bags despite the smaller net gain")

    directJob, task = startBagBatch()
    loot("You make 2 of " .. link .. ".", 5)
    assert(directJob.status == "running", "a creation message still waits for the carried reagent snapshot")
    bagUpdate(2, 2)
    assert(directJob.status == "complete" and task.evidence.confirmedByCreatedOutput == 2,
        "a localized aggregate creation notice can arrive before the bags update")

    directJob, task = startBagBatch()
    output[5764], output[4305], output[4234], output[2321] = 3, 0, 0, 0
    event("BAG_UPDATE_DELAYED")
    loot("You make 2 of " .. link .. ".", 6)
    advance(180)
    assert(directJob.status == "running" and task.completedExecutions == 0,
        "elapsed time, output and chat cannot settle the job with an inconsistent carried balance")
    event("TRADE_SKILL_CLOSE")
    assert(directJob.status == "uncertain" and task.completedExecutions == 0)
    UnitGUID = originalGUID
end)() end

do (function()
    local bags, bolt = recipe(6693, 197), recipe(3839, 197)
    bags.outputItemID, bolt.outputItemID = 5764, 4305
    for _, row in ipairs({bags, bolt}) do
        row.yield, row.yieldMax, row.completeness, row.characterKey = 1, 1, "complete", FC.state.characterKey
    end
    bags.reagents = {{itemID = 4305, quantity = 5}, {itemID = 4234, quantity = 3},
        {itemID = 2321, quantity = 3}, {itemID = 2605, quantity = 1}}
    bolt.reagents = {{itemID = 4306, quantity = 4}}
    FC.Catalog.Snapshot = function() return {recipesById = recipes, byOutput = {[4305] = {3839}}} end
    local recasts, clicks, nativeClicks = 0, 0, 0
    local reliable, source = true, "builtin"
    FC.InventoryAdapter.GetStatus = function()
        return {source = source, sourceGeneration = 1, reliable = reliable}
    end
    C_TradeSkillUI = {GetRemainingRecasts = function() return recasts end}
    UnitCastingInfo, UnitChannelInfo = function() end, function() end
    FC.Clients.Resolve = function(task)
        local row = recipes[task.recipeId]
        return {kind = "forever", recipeID = row.id, maxYield = 1, choice = row.reagents}
    end
    FC.Clients.CanDispatchQueuedCraft = function(live) return live.recipeID == 6693 end
    FC.Clients.DispatchQueuedCraft = function(task, _, batch, beforeClick)
        clicks = clicks + 1
        assert(task.recipeId == 6693 and (batch == 4 or batch == 2) and beforeClick(batch))
        return true, nil, batch
    end
    FC.Clients.Craft = function(task, _, batch)
        nativeClicks = nativeClicks + 1
        assert(task.recipeId == 6693 and batch == 2)
        return true, nil, "native_click", batch
    end
    FC.version = "0.2.52-dev"
    local function order(quantity, reserveMaterials)
        open, recasts, source, reliable, timers = 197, 0, "builtin", true, {}
        quantity = quantity or 4
        local state = {}
        assert(FC.Queue.Initialize(state))
        loadModule("Execution")
        output[5764], output[4305], output[4306] = 0, 0, 20 * quantity
        output[4234], output[2321], output[2605] = 3 * quantity, 3 * quantity, quantity
        local peer, missing = nil, false
        if reserveMaterials then peer, missing = reserveMaterials() end
        local function preview()
            return FC.Logistics.Preview({recipeId = 6693, quantity = quantity, intent = "additional", bagsOnly = not missing,
                choices = {[4305] = {source = "Make"}}})
        end
        local job = assert(FC.Queue.Accept(preview(), preview))
        local producer, root = job.tasks[1], job.tasks[2]
        local bolts = 5 * quantity
        assert(producer.recipeId == 3839 and producer.executions == bolts
            and root.recipeId == 6693 and root.executions == quantity)
        assert(FC.Queue.Begin(job, producer, {beforeOutput = 0, batch = bolts, maxYield = 1}))
        FC.Queue.CraftEvent(job, producer, bolts, bolts)
        output[4305], output[4306] = bolts, 0
        assert(FC.Queue.Reconcile(job, producer, bolts))
        return state, job, root, peer
    end
    local function reload(state)
        timers = {}
        assert(FC.Queue.Initialize(state))
        loadModule("Execution")
    end
    local function carryTwo()
        output[5764], output[4305], output[4234], output[2321], output[2605] = 2, 10, 6, 6, 2
    end
    local function inventoryChanged()
        event("BAG_UPDATE_DELAYED")
        advance(0)
    end

    local state, job, task = order()
    assert(FC.Execution.ProcessClick(job, task) and task.evidence.carriedStock.inputs[4305].before == 20)
    carryTwo()
    inventoryChanged()
    assert(task.evidence.carriedStock.executions == 2 and task.completedExecutions == 0,
        "the precise two-pack receipt is durable while the accepted four-operation batch remains active")
    reload(state)
    recasts = 1
    inventoryChanged()
    assert(job.status == "uncertain" and task.completedExecutions == 0, "live recasts keep a saved batch held")
    recasts, output[5764] = 0, 0
    event("UPDATE_TRADESKILL_CAST_STOPPED", false)
    advance(0)
    assert(job.status == "queued" and task.completedExecutions == 2 and task.remainingExecutions == 2
        and task.recoveredAttempts[1].kind == "stock" and clicks == 1 and nativeClicks == 0,
        "the witnessed partial settles once after reload even if the observed output moved")

    state, job, task = order()
    assert(FC.Execution.ProcessClick(job, task))
    event("UNIT_SPELLCAST_SUCCEEDED", "player", "green-silk-pack-one", 6693)
    event("UNIT_SPELLCAST_SUCCEEDED", "player", "green-silk-pack-two", 6693)
    assert(task.evidence.exactPlayerCastCount == 2 and not task.evidence.carriedStock.executions)
    reload(state)
    carryTwo()
    output[2605] = 3
    inventoryChanged()
    assert(job.status == "uncertain" and task.completedExecutions == 0,
        "the output and casts still need consistent consumption of every exact reagent")
    output[2605], source = 2, "syndicator"
    inventoryChanged()
    assert(job.status == "uncertain", "a differently sourced bag count cannot corroborate this saved baseline")
    source, reliable = "builtin", false
    inventoryChanged()
    assert(job.status == "uncertain", "an unqualified bag snapshot cannot corroborate the attempt")
    reliable = true
    inventoryChanged()
    assert(job.status == "queued" and task.completedExecutions == 2 and task.remainingExecutions == 2,
        "exact persisted player casts plus later corroborated bags resume this same job")

    state, job, task = order()
    assert(FC.Queue.Begin(job, task, {beforeOutput = 0, batch = 4, maxYield = 1,
        recipeId = 6693, professionId = 197, dispatch = "process", inventoryRevision = "builtin:1:2:3"}))
    FC.Queue.MarkUncertain(job, task, FC.L.execTimedOut)
    reload(state)
    carryTwo()
    open, recasts, output[4234] = nil, nil, 5 -- One already-acquired unit is currently outside bags.
    inventoryChanged()
    assert(job.status == "uncertain" and task.completedExecutions == 0, "a bare later stock gain stays unproved")
    local recovery = assert(FC.Execution.GetCarriedOutputRecovery(job))
    assert(recovery.jobId == job.id and recovery.taskId == task.taskId and recovery.itemID == 5764
        and recovery.quantity == 2 and recovery.remainingExecutions == 2)
    output[5764] = 1
    assert(not FC.Execution.ResumeWithCarriedOutput(job, recovery) and task.completedExecutions == 0,
        "a stale displayed output count cannot change the queue")
    output[5764] = 2
    local ok, _, exact = FC.Execution.ResumeWithCarriedOutput(job, recovery)
    assert(ok and exact == task and FC.Queue.GetJob(job.id) == job and job.status == "queued"
        and task.completedExecutions == 2 and task.remainingExecutions == 2 and task.fulfilledFromCarried == 2
        and task.recoveredAttempts[1].kind == "carried" and task.recoveredAttempts[1].evidence.sawCraftEvent == false
        and not task.nativeHandoffOnly and FC.Queue.OutstandingOutput(job) == 2 and clicks == 2 and nativeClicks == 0,
        "explicitly counting the two carried packs preserves the job and the unproved attempt without replay")
    assert(not FC.Execution.ResumeWithCarriedOutput(job, recovery) and task.completedExecutions == 2,
        "a reused confirmation cannot consume the same carried stock twice")
    task.nativeHandoffOnly = true -- A legacy saved recovery must not reroute the revised Process action.
    reload(state)
    assert(not FC.Queue.AreJobInputsCarried(job, FC.InventoryAdapter.Count))
    assert(not FC.Execution.GetReadyRestockCraft(job), "the direct action waits for verified native idle")
    open, recasts = 197, 0
    local ready, readyBatch, readyJob, direct = FC.Execution.GetReadyRestockCraft(job)
    assert(ready == task and readyBatch == 1 and readyJob == job and direct,
        "the recovered final step offers the one execution already covered by carried stock")
    output[4234] = 6
    assert(FC.Queue.AreJobInputsCarried(job, FC.InventoryAdapter.Count))
    ready, readyBatch, readyJob, direct = FC.Execution.GetReadyRestockCraft(job)
    assert(ready == task and readyBatch == 2 and readyJob == job and direct)
    local _, _, _, phase = FC.Execution.ProcessClick(job, task)
    assert(phase == "dispatched" and clicks == 3 and nativeClicks == 0 and task.evidence.batch == 2,
        "once the missing material is gathered, a new press submits only the two remaining operations")
    output[5764], output[4305], output[4234], output[2321], output[2605] = 4, 0, 0, 0, 0
    inventoryChanged()
    assert(job.status == "complete" and task.completedExecutions == 4)

    state, job, task = order()
    assert(FC.Execution.ProcessClick(job, task))
    local link = "|cnIQ1:|Hitem:5764:0|h[Green Silk Pack]|h|r"
    carryTwo()
    local function loot(line)
        event("CHAT_MSG_LOOT", "You make: " .. link .. ".", "", "", "", "", "", 0, 0, "", 0, line, "")
    end
    loot(200)
    loot(200)
    loot(201)
    assert(task.evidence.confirmedByCreatedStock == 2 and FC.Queue.VisibleOutstandingOutput(job) == 2
        and task.completedExecutions == 0 and job.status == "running",
        "two distinct localized results with exact consumed inputs update the four-pack row in the same event")
    event("TRADE_SKILL_CRAFT_BEGIN", 6693)
    event("TRADE_SKILL_ITEM_CRAFTED_RESULT", {itemID = 5764, quantity = 1, operationID = 231})
    event("TRADE_SKILL_CRAFT_BEGIN", 6693)
    event("TRADE_SKILL_ITEM_CRAFTED_RESULT", {itemID = 5764, quantity = 1, operationID = 232})
    assert(task.evidence.matchedExecutions == 2 and FC.Queue.VisibleOutstandingOutput(job) == 2,
        "the native and chat receipts for the same two units cannot count twice")
    event("UPDATE_TRADESKILL_CAST_STOPPED", false)
    local remainder, batch, owner, directNext = FC.Execution.GetReadyRestockCraft(job)
    assert(remainder == task and batch == 2 and owner == job and directNext and not FC.Execution.IsBusy(),
        "the factual terminal event immediately advertises the same two remaining crafts to the Restock button")
    do
        local emit = FC.Emit
        local refreshes, advertised, profession = 0
        function FC:Emit(signal, ...)
            emit(self, signal, ...)
            if signal == "EXECUTION_CHANGED" then
                refreshes = refreshes + 1
                advertised = FC.Execution.GetReadyRestockCraft(job)
                profession = FC.Execution.GetRestockProfession()
            end
        end
        recasts = 1
        assert(not FC.Execution.GetReadyRestockCraft(job) and not FC.Execution.IsBusy(),
            "lingering native recasts can suppress the reminder after its tracked craft settles")
        event("UNIT_SPELLCAST_STOP", "party1", "someone-else", 6693)
        advance(0)
        assert(refreshes == 0, "another unit cannot wake the pending reminder")
        event("UNIT_SPELLCAST_STOP", "player", "pack-native-idle", 6693)
        advance(0)
        assert(refreshes == 0, "a stop event cannot publish the remainder while native recasts are active")
        event("UNIT_SPELLCAST_STOP", "player", "pack-native-idle", 6693)
        event("UPDATE_TRADESKILL_CAST_STOPPED", false)
        recasts = 0
        advance(0)
        assert(refreshes == 1 and advertised == task,
            "the next idle observation republishes the exact confirmed remainder without a second inventory change")
        event("UPDATE_TRADESKILL_CAST_STOPPED", false)
        advance(0)
        assert(refreshes == 1, "a consumed idle notification absorbs repeated stop events")

        local currentProfession = FC.Clients.CurrentProfessionID
        FC.Clients.CurrentProfessionID = function() end
        recasts = 1
        assert(not FC.Execution.GetRestockProfession(), "a queued profession cannot open while native recasts remain")
        event("UPDATE_TRADESKILL_CAST_STOPPED", false)
        recasts = nil
        advance(0)
        assert(refreshes == 2 and profession and profession.jobId == job.id
            and profession.taskId == task.taskId and profession.quantity == 2,
            "the exact profession opener republishes when the closed native session settles")
        FC.Clients.CurrentProfessionID, recasts = currentProfession, 0
        FC.Emit = emit
    end
    local beforeResume = clicks
    local resumed, _, sameJob, route = FC.Execution.ProcessClick(job, task)
    assert(resumed and sameJob == job and route == "dispatched" and clicks == beforeResume + 1
        and nativeClicks == 0 and task.completedExecutions == 2 and task.evidence.batch == 2,
        "a press immediately after the terminal event restarts only this order's witnessed remainder")
    advance(2)
    assert(job.status == "running" and task.evidence.batch == 2, "the stopped batch's timer cannot affect the new batch")
    output[5764], output[4305], output[4234], output[2321], output[2605] = 4, 0, 0, 0, 0
    inventoryChanged()
    assert(job.status == "complete" and task.completedExecutions == 4 and clicks == beforeResume + 1)

    state, job, task = order()
    local other = accept(6698, 197, 1, "unrelated-uncertain-head")
    recipe(6698, 197)
    assert(FC.Queue.Begin(other, other.tasks[1], {beforeOutput = 0, batch = 1}))
    local busy, busyReason = FC.Execution.ProcessClick(job, task)
    assert(not busy and busyReason == FC.L.execBusy, "an explicit target respects an unrelated active submission")
    FC.Queue.MarkUncertain(other, other.tasks[1])
    local selected, exactTask = FC.Queue.NextTask(197, job)
    assert(selected == job and exactTask == task)
    local beforeExact = clicks
    assert(FC.Execution.ProcessClick(job, task) and clicks == beforeExact + 1 and other.status == "uncertain",
        "an uncertain order for a different output cannot block an explicit selected work item")
    output[5764], output[4305], output[4234], output[2321], output[2605] = 4, 0, 0, 0, 0
    inventoryChanged()
    assert(job.status == "complete" and other.status == "uncertain")

    state, job, task = order()
    local conflicting = accept(6698, 197, 1, "same-output-uncertain")
    conflicting.tasks[1].outputItemID = task.outputItemID
    assert(FC.Queue.Begin(conflicting, conflicting.tasks[1], {beforeOutput = 0, batch = 1}))
    FC.Queue.MarkUncertain(conflicting, conflicting.tasks[1])
    local blocked, reason = FC.Execution.ProcessClick(job, task)
    assert(not blocked and reason == FC.L.execReview and job.status == "queued",
        "a selected order cannot create output that an unresolved attempt could claim")

    local originalClock, originalCast = GetTime, UnitCastingInfo
    local currentCast
    GetTime = function() return now end
    UnitCastingInfo = function(unit)
        assert(unit == "player")
        if currentCast then
            return "Green Silk Pack", "", nil, currentCast.start, currentCast.finish,
                true, currentCast.guid, false, currentCast.spell
        end
    end
    local function longCast(guid, spell)
        currentCast = {start = now * 1000, finish = (now + 44.8) * 1000, guid = guid, spell = spell}
    end
    local function carryMade(made)
        output[5764] = made
        for _, material in ipairs(bags.reagents) do output[material.itemID] = (4 - made) * material.quantity end
        inventoryChanged()
    end

    state, job, task = order()
    assert(FC.Execution.ProcessClick(job, task))
    for turn = 1, 2 do
        local guid = "green-pack-slow-" .. turn
        longCast(guid, 6693)
        event("TRADE_SKILL_CRAFT_BEGIN", 6693)
        event("UNIT_SPELLCAST_START", "player", guid, 6693)
        local cast = assert(FC.Execution.GetActiveCast(job, task))
        assert(cast.spellID == 6693 and cast.guid == guid
            and cast.startTimeMs == currentCast.start and cast.endTimeMs == currentCast.finish
            and not FC.Execution.GetActiveCast(job, {}),
            "the selected task displays only its own observed Blizzard cast interval")
        recasts = 0
        event("UPDATE_TRADESKILL_CAST_STOPPED", false)
        assert(FC.Execution.GetActiveCast(job, task).guid == guid,
            "zero remaining recasts cannot end the batch while Blizzard still reports its active last cast")
        event("UNIT_SPELLCAST_STOP", "player", "different-" .. guid, 6693)
        assert(FC.Execution.GetActiveCast(job, task).guid == guid,
            "a matching spell with a different cast GUID cannot clear the active interval")
        event("UNIT_SPELLCAST_SUCCEEDED", "player", "different-" .. guid, 6693)
        assert(not task.evidence.exactPlayerCastCount,
            "an unmatched success GUID must not become part of the selected craft's result stream")
        local revision = FC.Queue.GetRevision()
        advance(30.1)
        assert(task.status == "in_flight" and FC.Execution.IsBusy()
            and FC.Queue.GetRevision() == revision and FC.Queue.VisibleOutstandingOutput(job) == 5 - turn,
            "elapsed time alone does not alter the count or queue during a 44.8-second cast")
        advance(15)
        currentCast = nil
        event("UNIT_SPELLCAST_STOP", "player", guid, 6693)
        assert(not FC.Execution.GetActiveCast(job, task) and task.status == "in_flight",
            "an exact cast stop clears that interval without stopping the craft batch")
        recasts = 4 - turn
        event("UPDATE_TRADESKILL_CAST_STOPPED", false)
        local _, pendingReceipt = FC.Execution.GetActiveCast(job, task)
        assert(not pendingReceipt and task.status == "in_flight",
            "a per-operation stop with native recasts remaining cannot end the batch")
        event("TRADE_SKILL_ITEM_CRAFTED_RESULT", {itemID = 5764, quantity = 1, operationID = 669300 + turn})
        assert(FC.Queue.VisibleOutstandingOutput(job) == 4 - turn,
            "the native result updates each remaining count without waiting for the next recast or bag update")
        carryMade(turn)
    end
    recasts = 0
    event("UPDATE_TRADESKILL_CAST_STOPPED", false)
    assert(task.completedExecutions == 2 and task.remainingExecutions == 2 and job.status == "queued",
        "the same batch continues through multiple long recasts and settles only its witnessed partial output")

    for _, mismatch in ipairs({"spell", "guid"}) do
        state, job, task = order()
        assert(FC.Execution.ProcessClick(job, task))
        event("UNIT_SPELLCAST_START", "player", "queued-cast", 6693)
        longCast(mismatch == "guid" and "unowned-cast" or "queued-cast", mismatch == "spell" and 6698 or 6693)
        assert(not FC.Execution.GetActiveCast(job, task), "unrelated spell or cast GUID must never supply the workbench timer")
        local revision = FC.Queue.GetRevision()
        advance(180)
        event("UNIT_SPELLCAST_INTERRUPTED", "player", currentCast.guid, currentCast.spell)
        assert(FC.Execution.IsBusy() and task.status == "in_flight" and FC.Queue.GetRevision() == revision,
            "a different cast does not time out or settle the queue's active submission")
        currentCast = nil
        event("TRADE_SKILL_CLOSE")
        assert(task.status == "uncertain" and not FC.Execution.IsBusy())
    end

    state, job, task = order()
    assert(FC.Execution.ProcessClick(job, task))
    longCast("pack-terminal-late-receipt", 6693)
    event("TRADE_SKILL_CRAFT_BEGIN", 6693)
    event("UNIT_SPELLCAST_START", "player", "pack-terminal-late-receipt", 6693)
    advance(44.9)
    currentCast = nil
    event("UNIT_SPELLCAST_STOP", "player", "pack-terminal-late-receipt", 6693)
    event("UPDATE_TRADESKILL_CAST_STOPPED", false)
    local timing, waiting = FC.Execution.GetActiveCast(job, task)
    assert(not timing and waiting, "the observed native end can wait for its last receipt without showing a stale clock")
    local revision = FC.Queue.GetRevision()
    advance(180)
    assert(task.status == "in_flight" and FC.Queue.GetRevision() == revision,
        "an exact terminal event can wait for delayed evidence without a deadline")
    event("TRADE_SKILL_ITEM_CRAFTED_RESULT", {itemID = 5764, quantity = 1, operationID = 669399})
    assert(FC.Queue.VisibleOutstandingOutput(job) == 3, "the delayed result updates the remaining count immediately")
    carryMade(1)
    assert(task.completedExecutions == 1 and task.remainingExecutions == 3 and job.status == "queued",
        "the delayed exact result settles the stopped attempt and makes the remainder available")
    GetTime, UnitCastingInfo = originalClock, originalCast

    local leatherUser = recipe(6699, 197)
    leatherUser.yield, leatherUser.yieldMax, leatherUser.completeness = 1, 1, "complete"
    leatherUser.characterKey, leatherUser.reagents = FC.state.characterKey, {{itemID = 4234, quantity = 3}}
    local originalQuotes = FC.MarketAdapter.QuoteItems
    FC.MarketAdapter.QuoteItems = function() return {[4234] = 1} end
    local function verifyShortFinalBatch(creditRequirement)
        local _, job, task, peer = order(6, function()
            output[4234] = creditRequirement and 3 or 21
            local function peerPreview()
                return FC.Logistics.Preview({recipeId = leatherUser.id, quantity = 1, bagsOnly = true})
            end
            return assert(FC.Queue.Accept(peerPreview(), peerPreview)), creditRequirement
        end)
        local leather = job.requirements[1]
        output[4234] = 18
        if creditRequirement then
            assert(leather and leather.itemID == 4234 and leather.quantity == 18)
            assert(FC.Queue.CreditAcquisition(job, leather.id, 15, output[4234]) == 15 and leather.remaining == 3)
        else
            assert(not leather)
        end
        assert(job.tasks[1].status == "complete" and job.producedReservations["4305"] == 30
            and peer.reservations["4234"] == 3 and not FC.Queue.AreJobInputsCarried(job, FC.InventoryAdapter.Count))
        assert(FC.Queue.SetPaused(peer.id, true))

        local submitted = {}
        FC.Clients.DispatchQueuedCraft = function(exactTask, _, batch, authorize)
            assert(exactTask == task and authorize(batch))
            submitted[#submitted + 1] = batch
            return true, nil, batch
        end
        local currentProfession, switchProfession = FC.Clients.CurrentProfessionID, FC.Clients.SwitchProfession
        local profession
        FC.Clients.CurrentProfessionID = function() return profession, 2 end
        FC.Clients.SwitchProfession = function(id)
            profession = id
            return true
        end
        local opener = assert(FC.Execution.GetRestockProfession())
        assert(opener.jobId == job.id and opener.taskId == task.taskId and opener.quantity == 5
            and opener.professionID == 197 and FC.Execution.OpenRestockProfession(opener)
            and profession == 197 and #submitted == 0,
            "the Restock opener prepares the exact carried batch and leaves the craft for the next press")
        local ready, amount, owner, direct = FC.Execution.GetReadyRestockCraft(job)
        assert(ready == task and amount == 5 and owner == job and direct)
        local ok, _, processed, phase = FC.Execution.ProcessClick(owner, ready, true)
        assert(ok and processed == job and phase == "dispatched" and submitted[1] == 5 and #submitted == 1,
            "one Restock press launches all five craftable packs without consuming the other order's leather")
        output[5764] = 5
        for _, material in ipairs(bags.reagents) do
            output[material.itemID] = output[material.itemID] - 5 * material.quantity
        end
        inventoryChanged()
        assert(job.status == "queued" and task.completedExecutions == 5 and task.remainingExecutions == 1
            and FC.Queue.OutstandingOutput(job) == 1 and job.producedReservations["4305"] == 5
            and peer.reservations["4234"] == 3 and output[4234] == 3)
        assert(not FC.Execution.GetReadyRestockCraft(job) and not FC.Execution.ProcessClick(job) and #submitted == 1,
            "Process and Restock wait when only the other order's leather remains")
        output[4234] = 6
        if creditRequirement then
            assert(leather.remaining == 3 and FC.Queue.CreditAcquisition(job, leather.id, 3, output[4234]) == 3)
        end
        assert(FC.Execution.ProcessClick(job) and submitted[2] == 1 and #submitted == 2)
        output[5764], output[4305], output[4234], output[2321], output[2605] = 6, 0, 3, 0, 0
        inventoryChanged()
        assert(job.status == "complete" and task.completedExecutions == 6 and peer.reservations["4234"] == 3,
            "the final press fulfills the original six-pack order once")
        FC.Clients.CurrentProfessionID, FC.Clients.SwitchProfession = currentProfession, switchProfession
    end
    verifyShortFinalBatch(false)
    verifyShortFinalBatch(true)
    FC.MarketAdapter.QuoteItems = originalQuotes
end)() end

do (function()
    local id, item, material = "legacy:fp:197:621:2:3:410x2", 621, 410
    local recipe = {id = id, name = "Synthetic Classic Bolt", professionId = 197, learned = true,
        characterKey = FC.state.characterKey,
        revision = 1, outputKind = "item", outputItemID = item, yield = 2, yieldMax = 3,
        completeness = "complete", legacy = true, reagents = {{itemID = material, quantity = 2}}}
    local catalog = {recipesById = {[id] = recipe}}
    FC.target = "era"
    FC.Catalog = {Snapshot = function() return catalog end, Refresh = function() end}
    FC.InventoryAdapter.GetStatus = function() return {reliable = true, source = "builtin", sourceGeneration = 1} end
    FC.Clients = {
        CurrentProfessionID = function() return 197 end,
        Resolve = function() return {kind = "classic", choice = recipe.reagents, maxYield = 3} end,
        Craft = function(_, _, batch, authorize) return authorize(batch), nil, batch end,
    }
    C_TradeSkillUI = nil
    loadModule("Execution")
    local activeCast
    UnitCastingInfo = function()
        if activeCast then
            return activeCast.name, activeCast.name, 1, 10, 5000, true, activeCast.guid, nil, 8101
        end
    end
    local function cast(guid, name)
        activeCast = {name = name or recipe.name, guid = guid}
        event("UNIT_SPELLCAST_START", "player", guid, 8101)
    end
    local function acceptClassic()
        assert(FC.Queue.Initialize({}))
        output[item], output[material] = 0, 4
        local plan = FC.Planner.Preview({catalog = catalog, rootRecipeId = id, quantity = 4, inventory = output,
            characterKey = FC.state.characterKey})
        local job = assert(FC.Queue.Accept(plan, function() return plan end))
        return job, job.tasks[1]
    end

    local job, task = acceptClassic()
    assert(FC.Execution.ProcessNext(job, task))
    output[item], output[material] = 3, 2
    event("BAG_UPDATE_DELAYED")
    cast("unrelated", "Other Cast")
    event("UNIT_SPELLCAST_SUCCEEDED", "player", "unrelated", 8101)
    assert(task.status == "in_flight" and not task.evidence.sawCraftEvent,
        "matching stock and an unrelated cast cannot confirm an unlinked recipe")
    cast("unlinked-craft-1")
    assert(FC.Execution.GetActiveCast(job, task).guid == "unlinked-craft-1")
    event("UNIT_SPELLCAST_SUCCEEDED", "player", "wrong-guid", 8101)
    assert(not task.evidence.sawCraftEvent)
    event("UNIT_SPELLCAST_SUCCEEDED", "player", "unlinked-craft-1", 8101)
    assert(task.evidence.reportedOutput == 3 and FC.Queue.VisibleCompletedExecutions(task) == 1)
    cast("unlinked-craft-interrupted")
    activeCast = nil
    event("UNIT_SPELLCAST_INTERRUPTED", "player", "unlinked-craft-interrupted", 8101)
    assert(job.status == "queued" and task.completedExecutions == 1 and task.remainingExecutions == 1,
        "interruption retains only the qualified output and leaves the next craft ready")
    assert(FC.Execution.ProcessNext(job, task))
    cast("unlinked-craft-2")
    activeCast = nil
    event("UNIT_SPELLCAST_SUCCEEDED", "player", "unlinked-craft-2", 8101)
    output[item], output[material] = 5, 0
    event("BAG_UPDATE_DELAYED")
    assert(job.status == "complete" and task.completedExecutions == 2,
        "cast identity learned during the native click reconciles a ranged-yield Classic batch")

    job, task = acceptClassic()
    assert(FC.Execution.ProcessNext(job, task))
    local link = "|Hitem:" .. item .. "|h[Synthetic Classic Bolt]|h"
    local function loot(message, line)
        event("CHAT_MSG_LOOT", message, "", "", "", "", "", 0, 0, "", 0, line, "")
    end
    output[item], output[material] = 4, 0
    loot("You receive loot: " .. link .. ".", 422000)
    assert(not task.evidence.sawCraftEvent, "ordinary loot cannot supply the native creation receipt")
    loot("You make 4 of " .. link .. ".", 422001)
    assert(job.status == "complete" and task.completedExecutions == 2,
        "an exact self-creation receipt corroborates the output when no cast start was observed")
end)() end

print("native craft lifecycle and recovery tests passed")
