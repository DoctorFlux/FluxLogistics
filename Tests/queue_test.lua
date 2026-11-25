local FC = {state = {characterKey = "actor-A", build = 16001}}
local listeners = {}
function FC:On(signal, callback) listeners[signal] = callback end
function FC:Emit(signal, ...)
    if listeners[signal] then listeners[signal](self, ...) end
end
assert(loadfile("FluxCraft/Queue.lua"))("FluxLogistics", FC)

local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, child in pairs(value) do result[key] = copy(child) end
    return result
end

local function plan(owned)
    return {
        status = "ready", revision = "r1", rootRecipeId = "final", rootItemID = 900,
        summary = {output = 1}, requirements = {},
        tree = {itemID = 900, required = 1, source = "Make", children = {
            {itemID = 100, required = owned, ownedUsed = owned, source = "Owned", children = {}},
        }},
        tasks = {
            {taskId = "t1", recipeId = "final", professionId = 197,
                outputItemID = 900, outputKind = "item", yield = 1,
                outputQuantity = 1, executions = 1, dependencies = {"t2"}, inputs = {}},
            {taskId = "t2", recipeId = "bolt", professionId = 171,
                outputItemID = 200, outputKind = "item", yield = 2,
                outputQuantity = 2, executions = 1, dependencies = {}, inputs = {}},
        },
    }
end

local saved = {}
assert(FC.Queue.Initialize(saved))
local first = plan(4)
local job = assert(FC.Queue.Accept(first, function() return copy(first) end))
assert(job.id == 1 and FC.Queue.Reserved()["100"] == 4)
assert(FC.Queue.AvailableInventory({[100] = 7})[100] == 3)
local nextJob, task = FC.Queue.NextTask(171)
assert(nextJob == job and task.taskId == "t2")
assert(FC.Queue.Begin(job, task, {beforeOutput = 0, batch = 1}))
assert(not FC.Queue.Reconcile(job, task, 2), "output alone is not craft evidence")
FC.Queue.CraftEvent(job, task)
assert(FC.Queue.Reconcile(job, task, 2))
assert(task.status == "complete" and job.producedReservations["200"] == 2)
nextJob, task = FC.Queue.NextTask(197)
assert(nextJob == job and task.taskId == "t1")
assert(FC.Queue.Begin(job, task, {beforeOutput = 0, batch = 1}))
FC.Queue.CraftEvent(job, task)
assert(FC.Queue.Reconcile(job, task, 1))
assert(job.status == "complete" and next(FC.Queue.Reserved()) == nil)

local second = plan(3)
second.revision = "r2"
local third = plan(2)
third.revision = "r3"
local job2 = assert(FC.Queue.Accept(second, function() return copy(second) end))
local job3 = assert(FC.Queue.Accept(third, function() return copy(third) end))
assert(FC.Queue.Reserved()["100"] == 5)
assert(FC.Queue.Cancel(job2.id))
assert(FC.Queue.Reserved()["100"] == 2, "cancel released another job's stock")
assert(job3.status == "queued")

local stale = copy(third)
stale.revision = "changed"
assert(not FC.Queue.Accept(third, function() return stale end), "stale acceptance succeeded")

local activeJob, activeTask = FC.Queue.NextTask(171)
assert(activeJob == job3 and activeTask.taskId == "t2")
assert(FC.Queue.Begin(activeJob, activeTask, {beforeOutput = 5, batch = 1}))
FC.Queue.Initialize(saved) -- simulate reload
assert(activeTask.status == "uncertain" and activeJob.status == "uncertain")
assert(not FC.Queue.Reconcile(activeJob, activeTask, 7), "reload replayed without cast evidence")
assert(FC.Queue.Cancel(activeJob.id), "explicit cancellation should release only this job")
assert(next(FC.Queue.Reserved()) == nil)

local partialPlan = plan(0)
partialPlan.revision = "partial"
partialPlan.tasks[2].executions = 2
partialPlan.tasks[2].outputQuantity = 4
local partialJob = assert(FC.Queue.Accept(partialPlan, function() return copy(partialPlan) end))
local _, partialTask = FC.Queue.NextTask(171)
assert(FC.Queue.Begin(partialJob, partialTask, {beforeOutput = 5, batch = 2}))
FC.Queue.CraftEvent(partialJob, partialTask, 1)
assert(not FC.Queue.Reconcile(partialJob, partialTask, 7) and partialTask.evidence.carriedResult,
    "a live partial result must retain its matching carried output until the batch stops")
FC.Queue.MarkUncertain(partialJob, partialTask, "batch interrupted")
assert(FC.Queue.ReconcilePartial(partialJob, partialTask))
assert(partialTask.completedExecutions == 1 and partialTask.remainingExecutions == 1)
assert(partialTask.status == "pending" and partialJob.status == "queued")

local laterResultPlan = copy(partialPlan)
laterResultPlan.revision = "unwitnessed-later-result"
local laterResultJob = assert(FC.Queue.Accept(laterResultPlan, function() return copy(laterResultPlan) end))
local laterResult = laterResultJob.tasks[2]
assert(FC.Queue.Begin(laterResultJob, laterResult, {beforeOutput = 0, batch = 2}))
FC.Queue.CraftEvent(laterResultJob, laterResult, 1, 2)
assert(not FC.Queue.Reconcile(laterResultJob, laterResult, 2) and laterResult.evidence.carriedResult)
FC.Queue.CraftEvent(laterResultJob, laterResult, 1, 2)
FC.Queue.MarkUncertain(laterResultJob, laterResult)
assert(not FC.Queue.Reconcile(laterResultJob, laterResult, 4) and not FC.Queue.ReconcilePartial(laterResultJob, laterResult),
    "an earlier checkpoint cannot settle or replay a later native result with no matching carried observation")
assert(FC.Queue.Cancel(laterResultJob.id))

local rivalPlan = plan(2)
rivalPlan.revision = "unrelated-edit"
local rival = assert(FC.Queue.Accept(rivalPlan, function() return copy(rivalPlan) end))
local revised = plan(1)
revised.revision = "edit-only-remaining"
local replacement = assert(FC.Queue.Accept(revised, function() return copy(revised) end, partialJob))
assert(partialJob.status == "replaced" and partialJob.replacement == replacement.id)
assert(not FC.Queue.Cancel(partialJob.id) and partialJob.status == "replaced", "replacement history must stay intact")
assert(partialTask.completedExecutions == 1 and partialTask.evidence.afterOutput == 7,
    "editing remaining work lost completed craft history")
assert(FC.Queue.GetJob(rival.id) == rival and FC.Queue.Reserved()["100"] == 3)

local prerequisite = replacement.tasks[2]
assert(FC.Queue.Begin(replacement, prerequisite, {beforeOutput = 0, batch = 1}))
FC.Queue.InvalidateRecipes({recipesById = {final = {learned = false}}})
assert(replacement.status == "running" and replacement.invalidatedAfterAction)
assert(replacement.reservations["100"] == 1, "unlearning released stock during an active action")
FC.Queue.CraftEvent(replacement, prerequisite, 1)
assert(FC.Queue.Reconcile(replacement, prerequisite, 2))
assert(replacement.status == "invalidated" and next(replacement.reservations) == nil)

local interruptedPlan = plan(1)
interruptedPlan.revision = "unlearn-uncertain-batch"
interruptedPlan.tasks[2].executions = 2
interruptedPlan.tasks[2].outputQuantity = 4
local interrupted = assert(FC.Queue.Accept(interruptedPlan, function() return copy(interruptedPlan) end))
local interruptedTask = interrupted.tasks[2]
assert(FC.Queue.Begin(interrupted, interruptedTask, {beforeOutput = 0, batch = 2}))
FC.Queue.CraftEvent(interrupted, interruptedTask, 1)
assert(not FC.Queue.AbortBeforeSubmission(interrupted, interruptedTask, interruptedTask.evidence),
    "matched craft evidence prevents aborting a dispatched attempt")
assert(not FC.Queue.Reconcile(interrupted, interruptedTask, 2) and interruptedTask.evidence.carriedResult)
FC.Queue.MarkUncertain(interrupted, interruptedTask, "batch interrupted")
FC.Queue.InvalidateRecipes({recipesById = {bolt = {learned = false}}})
assert(interrupted.status == "uncertain" and interrupted.reservations["100"] == 1)
FC.Queue.Initialize(saved) -- the deferred invalidation survives reload
assert(FC.Queue.ReconcilePartial(interrupted, interruptedTask))
assert(interrupted.status == "invalidated" and next(interrupted.reservations) == nil
    and interruptedTask.completedExecutions == 1 and interruptedTask.remainingExecutions == 1,
    "verified partial output survives invalidation of the unlearned remainder")

local completedPlan = plan(1)
completedPlan.revision = "unlearn-but-final-action-complete"
completedPlan.tasks = {completedPlan.tasks[2]}
completedPlan.rootRecipeId, completedPlan.rootItemID = "bolt", 200
completedPlan.tree.itemID = 200
local completed = assert(FC.Queue.Accept(completedPlan, function() return copy(completedPlan) end))
local completedTask = completed.tasks[1]
assert(FC.Queue.Begin(completed, completedTask, {beforeOutput = 0, batch = 1}))
FC.Queue.InvalidateRecipes({recipesById = {bolt = {learned = false}}})
assert(completed.status == "running" and completed.reservations["100"] == 1)
FC.Queue.CraftEvent(completed, completedTask, 1)
assert(FC.Queue.Reconcile(completed, completedTask, 2))
assert(completed.status == "complete" and completedTask.completedExecutions == 1
    and next(completed.reservations) == nil, "a fully confirmed final craft remains complete")

assert(FC.Queue.Initialize({}))
local function acceptForOrdering(label, owned)
    local request = plan(owned)
    request.revision = label
    return assert(FC.Queue.Accept(request, function() return copy(request) end))
end
local first = acceptForOrdering("first", 1)
local invalidated = acceptForOrdering("invalidated", 2)
local last = acceptForOrdering("last", 3)
invalidated.status, invalidated.reservations = "invalidated", {}
local reserved = FC.Queue.Reserved()["100"]
assert(FC.Queue.Move(last.id, -1))
local ordered = FC.Queue.GetJobs()
assert(ordered[1] == last and ordered[2] == invalidated and ordered[3] == first
    and FC.Queue.Reserved()["100"] == reserved, "an invalidated job must preserve its history without obstructing reordering")

-- Two sub-combines share one shopping line. The first can use the credited
-- units before the rest arrive, and its finished work cannot spend them twice.
assert(loadfile("FluxCraft/Locale.lua"))("FluxLogistics", FC)
assert(loadfile("FluxCraft/Planner.lua"))("FluxLogistics", FC)
local partialSaved = {}
assert(FC.Queue.Initialize(partialSaved))
local physical = 0
FC.InventoryAdapter = {Count = function() return physical end}
local function knownRecipe(id, output, reagents)
    return {id = id, professionId = 171, characterKey = FC.state.characterKey, outputItemID = output,
        outputKind = "item", learned = true, completeness = "complete", yield = 1, reagents = reagents}
end
local short = knownRecipe(1, 201, {{itemID = 300, quantity = 2}})
local long = knownRecipe(2, 202, {{itemID = 300, quantity = 8}})
local final = knownRecipe(3, 203, {{itemID = 202, quantity = 1}, {itemID = 201, quantity = 1}})
local function previewShared()
    return FC.Planner.Preview({rootRecipeId = 3, quantity = 1, characterKey = FC.state.characterKey,
        catalog = {recipesById = {short, long, final}, byOutput = {[201] = {1}, [202] = {2}}},
        quotes = {[300] = 10}})
end
local shared = assert(FC.Queue.Accept(previewShared(), previewShared))
assert(#shared.tasks == 3 and #shared.requirements == 1 and shared.requirements[1].quantity == 10)
local longTask, shortTask = shared.tasks[1], shared.tasks[2]
assert(shortTask.recipeId == 1 and longTask.recipeId == 2 and not FC.Queue.NextTask(171, shared))
physical = 2
assert(FC.Queue.CreditAcquisition(shared, 1, 2, physical) == 2)
local selectedJob, selectedTask = FC.Queue.NextTask(171, shared)
assert(selectedJob == shared and selectedTask == shortTask and not FC.Queue.CanProcess(shared, longTask))
assert(FC.Queue.Begin(shared, shortTask, {beforeOutput = 0, batch = 1}))
FC.Queue.CraftEvent(shared, shortTask, 1)
physical = 0
assert(FC.Queue.Reconcile(shared, shortTask, 1))
assert(shortTask.status == "complete" and not shared.reservations["300"] and not FC.Queue.NextTask(171, shared))

assert(loadfile("FluxCraft/Graph.lua"))("FluxLogistics", FC)
local graph = setmetatable({Relayout = function() end, Paint = function() end, onTooltip = function() end},
    {__index = FC.Graph})
local function graphTooltip(job, node, collapsed)
    local lines = {}
    GameTooltip = {
        IsOwned = function() return true end,
        AddLine = function(_, line) lines[line] = true end,
        Show = function() end,
    }
    graph:Render(job.tree, {zoom = 1}, collapsed or {}, nil, nil, job)
    graph:ShowTooltip({entry = {node = node}})
    GameTooltip = nil
    return lines
end

local longBranch, shortBranch = shared.tree.children[1], shared.tree.children[2]
assert(longBranch.itemID == 202 and shortBranch.itemID == 201)
local sharedReceipt = FC.L.nodeSharedReceipt:format(2, 8)
local bigInput = graphTooltip(shared, longBranch.children[1], {["203/2-201"] = true})
local smallInput = graphTooltip(shared, shortBranch.children[1])
assert(bigInput[sharedReceipt] and smallInput[sharedReceipt]
    and not bigInput[FC.L.nodeProgress:format(2, 8)] and not smallInput[FC.L.nodeProgress:format(0, 2)],
    "a shared receipt must remain a plan total when branches render in a different order or fold")
assert(graphTooltip(shared, longBranch)[FC.L.noReadyCraft] and graphTooltip(shared, shortBranch)[FC.L.complete],
    "the completed and blocked craft nodes must show their real states")

local unshared = {tasks = {}, requirements = {{requirementId = "unshared", quantity = 4, remaining = 1}},
    tree = {source = "Buy", purchases = {{kind = "manual", requirementId = "unshared", quantity = 4}}}}
assert(graphTooltip(unshared, unshared.tree)[FC.L.nodeProgress:format(3, 4)],
    "a legacy unshared purchase keeps its exact carried receipt")

local vendorFirst = {source = "Vendor", purchases = {{kind = "vendor", requirementId = "bundled", purchased = 5}}}
local vendorSecond = copy(vendorFirst)
local bundled = {tasks = {}, tree = {source = "Make", children = {vendorFirst, vendorSecond}},
    requirements = {{kind = "vendor", requirementId = "bundled", quantity = 10, remaining = 3, bundleSize = 5}},
    allocations = {{requirementId = "bundled", quantity = 5}, {requirementId = "bundled", quantity = 2}}}
assert(graphTooltip(bundled, vendorSecond)[FC.L.nodeSharedReceipt:format(7, 0)],
    "units needed by the craft can be satisfied without receiving planned vendor surplus")

physical = 6
assert(FC.Queue.CreditAcquisition(shared, 1, 6, physical) == 6)
FC.Queue.Initialize(partialSaved)
assert(shared.requirements[1].remaining == 2 and shared.reservations["300"] == 6
    and not FC.Queue.CanProcess(shared, longTask), "the prior craft's two units cannot count toward its sibling")
physical = 8
assert(FC.Queue.CreditAcquisition(shared, 1, 2, physical) == 2)
selectedJob, selectedTask = FC.Queue.NextTask(171, shared)
assert(selectedJob == shared and selectedTask == longTask)
assert(FC.Queue.Begin(shared, longTask, {beforeOutput = 0, batch = 1}))
FC.Queue.CraftEvent(shared, longTask, 1)
assert(FC.Queue.Reconcile(shared, longTask, 1) and not shared.reservations["300"])
selectedJob, selectedTask = FC.Queue.NextTask(171, shared)
assert(selectedJob == shared and selectedTask.recipeId == 3)

-- A positive learned-rank observation invalidates outstanding work while
-- retaining exact accepted recipes and native evidence after a reload.
FC.target = "forever"
local rankSaved = {}
assert(FC.Queue.Initialize(rankSaved))
local rankPlan = plan(2)
rankPlan.tasks[2].recipeId, rankPlan.tasks[2].executions = 41, 2
rankPlan.requirements = {{kind = "vendor", itemID = 300, quantity = 1}}
local function acceptRankPlan(revision)
    rankPlan.revision = revision
    return assert(FC.Queue.Accept(rankPlan, function() return copy(rankPlan) end))
end
local idleRank, activeRank = acceptRankPlan("idle-rank"), acceptRankPlan("active-rank")
local rankTask = activeRank.tasks[2]
assert(FC.Queue.Begin(activeRank, rankTask, {beforeOutput = 0, batch = 2}))
FC.Queue.CraftEvent(activeRank, rankTask, 1)
assert(not FC.Queue.Reconcile(activeRank, rankTask, 2) and rankTask.evidence.carriedResult)

local rankReason = FC.L.clients.supersededRank
local rankCatalog = {recipesById = {[41] = {id = 41, learned = true,
    supersededByRecipeID = 42, blockedReason = rankReason}}}
FC.Queue.InvalidateRecipes(rankCatalog)
assert(idleRank.status == "invalidated" and idleRank.invalidationReason == rankReason
    and idleRank.tasks[2].recipeId == 41 and idleRank.tasks[2].blocker == rankReason
    and next(idleRank.reservations) == nil and #FC.Queue.GetRequirements(idleRank) == 0)
assert(FC.Queue.CreditAcquisition(idleRank, 1, 1, 1) == 0 and not next(idleRank.reservations),
    "a stale carried-stock reconciliation cannot reallocate inventory to an invalidated job")
assert(activeRank.status == "running" and activeRank.reservations["100"] == 2
    and activeRank.invalidatedActiveReason == rankReason, "active craft retains the exact handle and its reservations")
FC.Queue.Initialize(rankSaved)
assert(FC.Queue.ReconcilePartial(activeRank, rankTask))
assert(activeRank.status == "invalidated" and activeRank.invalidationReason == rankReason
    and rankTask.recipeId == 41 and rankTask.blocker == rankReason and rankTask.completedExecutions == 1
    and next(activeRank.reservations) == nil and #FC.Queue.GetRequirements(activeRank) == 0)

local clearSaved = {}
assert(FC.Queue.Initialize(clearSaved))
local function clearPlan(revision, owned)
    local candidate = plan(owned)
    candidate.revision = revision
    candidate.tasks[2].executions, candidate.tasks[2].outputQuantity = 2, 4
    candidate.summary.requested = 1
    return candidate
end
local clearablePlan = clearPlan("clearable", 3)
local clearable = assert(FC.Queue.Accept(clearablePlan, function() return copy(clearablePlan) end))
local livePlan = clearPlan("live-craft-clear", 1)
livePlan.requirements = {{kind = "auction", itemID = 380, quantity = 5}}
local liveJob = assert(FC.Queue.Accept(livePlan, function() return copy(livePlan) end))
assert(FC.Queue.CanGroup(clearable, liveJob), "only the accepted job lots keep separate material limits")
local directRoute = copy(liveJob)
directRoute.tasks = {directRoute.tasks[1]}
assert(FC.Queue.CanGroup(liveJob, directRoute), "carried intermediates can replace default Auto production")
directRoute.tasks[1].inputs = {{itemID = 920, quantity = 1, slotIndex = 1}}
assert(not FC.Queue.CanGroup(liveJob, directRoute), "different exact reagent selections stay separate")
local otherDestination = copy(liveJob)
otherDestination.goal.destination = {actorKey = "actor-B", locationKey = "bags"}
assert(not FC.Queue.CanGroup(liveJob, otherDestination))
local explicitSource = copy(liveJob)
explicitSource.goal.sourceChoices = {["380"] = {source = "vendor"}}
assert(not FC.Queue.CanGroup(liveJob, explicitSource))
local liveTask = liveJob.tasks[2]
assert(FC.Queue.Begin(liveJob, liveTask, {beforeOutput = 0, batch = 2}))
FC.Queue.CraftEvent(liveJob, liveTask, 1, 2)
assert(not FC.Queue.Reconcile(liveJob, liveTask, 2) and liveTask.evidence.carriedResult)
assert(not FC.Queue.CancelGroup({clearable, liveJob}) and clearable.status == "queued",
    "a grouped X must leave all members alone while a member has a native action")
assert(FC.Queue.Clear() and clearable.status == "cancelled" and FC.Queue.IsClearing(liveJob))
assert(liveJob.reservations["100"] == 1 and not FC.Queue.CanProcess(liveJob, liveJob.tasks[1])
    and not FC.Queue.CanReplace(liveJob) and FC.Queue.OutstandingOutput(liveJob) == 0
    and #FC.Queue.GetRequirements(liveJob) == 0 and liveTask.status == "in_flight",
    "Clear hides future work but preserves the exact native attempt and holds")
assert(FC.Queue.Initialize(clearSaved))
assert(liveJob.status == "cancelled" and liveTask.completedExecutions == 1 and liveTask.evidence.afterOutput == 2
    and liveTask.remainingExecutions == 1 and next(FC.Queue.Reserved()) == nil
    and FC.Queue.CanGroup(clearable, liveJob), "reload archives cleared work and retains the exact confirmed partial result")

for _, source in ipairs({"auction", "vendor"}) do
    local shoppingPlan = clearPlan("issued-shopping-clear-" .. source, 2)
    shoppingPlan.requirements = {{kind = source, itemID = 381, quantity = 5}}
    local shoppingJob = assert(FC.Queue.Accept(shoppingPlan, function() return copy(shoppingPlan) end))
    local shoppingRequirement = shoppingJob.requirements[1]
    shoppingRequirement.auctionAwaiting, shoppingRequirement.auctionSpent = 2, 120
    shoppingJob.acquisition = {kind = "auction", status = "issued", index = 1, quantity = 2}
    assert(FC.Queue.Clear() and FC.Queue.IsClearing(shoppingJob) and shoppingJob.auctionReceiptsReleased
        and shoppingJob.reservations["100"] == 2 and shoppingJob.acquisition.status == "issued")
    shoppingRequirement.auctionAwaiting, shoppingRequirement.auctionSpent = 4, 240
    local confirmedAction = shoppingJob.acquisition
    confirmedAction.status, shoppingJob.lastAcquisition, shoppingJob.acquisition = "confirmed", confirmedAction, nil
    assert(FC.Queue.FinishDeferredInvalidation(shoppingJob) and shoppingJob.status == "cancelled"
        and shoppingJob.lastAcquisition == confirmedAction and #FC.Queue.GetRequirements(shoppingJob) == 0
        and shoppingRequirement.kind == source
        and shoppingRequirement.auctionAwaiting == 4 and shoppingRequirement.auctionSpent == 240
        and next(FC.Queue.Reserved()) == nil, "clearing preserves paid receipts for either planned source")
end

local uncertainPlan = clearPlan("unconfirmed-shopping-clear", 2)
uncertainPlan.requirements = {{kind = "vendor", itemID = 382, quantity = 5}}
local uncertainJob = assert(FC.Queue.Accept(uncertainPlan, function() return copy(uncertainPlan) end))
local uncertainAction = {kind = "vendor", status = "issued", index = 1, quantity = 5}
uncertainJob.acquisition = uncertainAction
assert(FC.Queue.Clear() and FC.Queue.IsClearing(uncertainJob))
uncertainAction.status = "uncertain"
FC:Emit("ACQUISITION_CHANGED", "uncertain", {job = uncertainJob})
assert(uncertainJob.status == "cancelled" and uncertainJob.acquisition == uncertainAction
    and uncertainJob.acquisition.status == "uncertain" and next(FC.Queue.Reserved()) == nil,
    "an unresolved receipt retains its journal and cannot leave a hidden clearing job in the way")

do
    local vendorSave = {}
    assert(FC.Queue.Initialize(vendorSave))
    local purchasePlan = clearPlan("parallel-vendor-receipts", 2)
    purchasePlan.requirements = {
        {kind = "vendor", itemID = 811, quantity = 5},
        {kind = "vendor", itemID = 812, quantity = 7},
        {kind = "vendor", itemID = 813, quantity = 9},
        {kind = "vendor", itemID = 811, quantity = 2},
    }
    local function accept(revision)
        purchasePlan.revision = revision
        return assert(FC.Queue.Accept(purchasePlan, function() return copy(purchasePlan) end))
    end
    local function journal(index, quantity)
        return {kind = "vendor", status = "issued", index = index, quantity = quantity, credited = 0}
    end
    local order = accept("parallel-vendor-receipts")
    local thread, dye, leather = journal(1, 5), journal(2, 7), journal(3, 9)
    order.acquisition = {kind = "bank", status = "issued", index = 1}
    assert(not FC.Queue.AddVendorAcquisition(order, dye), "a non-vendor receipt remains exclusive")
    order.acquisition = nil
    assert(FC.Queue.AddVendorAcquisition(order, thread))
    thread.dispatching = true
    assert(not FC.Queue.AddVendorAcquisition(order, dye), "a native call cannot re-enter the vendor pass")
    thread.dispatching = nil
    assert(not FC.Queue.AddVendorAcquisition(order, journal(4, 2)), "the same SKU still waits for its earlier receipt")
    assert(FC.Queue.AddVendorAcquisition(order, leather) and FC.Queue.AddVendorAcquisition(order, dye))
    local actions = FC.Queue.Acquisitions(order)
    assert(actions[1] == thread and actions[2] == dye and actions[3] == leather
        and FC.Queue.GetAcquisition(order) == thread and FC.Queue.GetAcquisition(order, 3) == leather)
    assert(not FC.Queue.CanReplace(order) and not FC.Queue.Cancel(order.id), "all issued materials protect the order")
    assert(FC.Queue.CreditAcquisition(order, 3, 9, 9) == 9 and leather.status == "confirmed"
        and not FC.Queue.GetAcquisition(order, 3) and FC.Queue.GetAcquisition(order) == thread,
        "stock for a supplemental material only resolves its own receipt")
    assert(FC.Queue.CreditAcquisition(order, 1, 5, 5) == 5 and thread.status == "confirmed"
        and FC.Queue.GetAcquisition(order) == dye and not order.vendorAcquisitions,
        "settling the primary material promotes the outstanding receipt")
    assert(FC.Queue.HasIssuedAcquisition(order) and not FC.Queue.Cancel(order.id))
    assert(FC.Queue.CreditAcquisition(order, 2, 7, 7) == 7 and dye.status == "confirmed"
        and not FC.Queue.GetAcquisition(order) and FC.Queue.CanReplace(order))

    local reloaded = accept("parallel-vendor-reload")
    thread, dye = journal(1, 5), journal(2, 7)
    assert(FC.Queue.AddVendorAcquisition(reloaded, thread) and FC.Queue.AddVendorAcquisition(reloaded, dye))
    thread.status, dye.dispatching = "uncertain", true
    assert(FC.Queue.HasIssuedAcquisition(reloaded) and not FC.Queue.Cancel(reloaded.id),
        "an uncertain primary receipt cannot hide a still-issued supplemental receipt")
    assert(FC.Queue.Initialize(copy(vendorSave)))
    reloaded = assert(FC.Queue.GetJob(reloaded.id))
    actions = FC.Queue.Acquisitions(reloaded)
    assert(#actions == 2 and actions[1].status == "uncertain" and actions[2].status == "uncertain"
        and not actions[2].dispatching and not FC.Queue.HasIssuedAcquisition(reloaded)
        and not FC.Queue.CanReplace(reloaded), "all outstanding receipts survive reload and require observation or review")
    assert(not FC.Queue.CloseAcquisition(reloaded, thread), "a superseded receipt cannot affect a reloaded order")
    assert(FC.Queue.CloseAcquisition(reloaded, actions[2]) and FC.Queue.GetAcquisition(reloaded) == actions[1])
    assert(FC.Queue.CloseAcquisition(reloaded) and not FC.Queue.GetAcquisition(reloaded))

    local clearing = accept("parallel-vendor-clear")
    thread, dye = journal(1, 5), journal(2, 7)
    assert(FC.Queue.AddVendorAcquisition(clearing, thread) and FC.Queue.AddVendorAcquisition(clearing, dye))
    thread.status = "uncertain"
    assert(FC.Queue.Clear() and FC.Queue.IsClearing(clearing))
    assert(FC.Queue.CreditAcquisition(clearing, 2, 7, 7) == 7
        and clearing.status == "cancelled" and FC.Queue.GetAcquisition(clearing) == thread,
        "Clear waits for all issued receipts and archives unresolved items separately")
end

local materialSave = {}
assert(FC.Queue.Initialize(materialSave))
local materialPlan = plan(0)
materialPlan.revision = "material-protection"
materialPlan.tasks[1].inputs = {{itemID = 200, quantity = 2}, {itemID = 8100, quantity = 1}}
materialPlan.tasks[2].inputs = {{itemID = "8101", quantity = 2}}
assert(next(FC.Queue.GetCraftMaterialIDs()) == nil, "an unaccepted plan does not protect items")
local materialJob = assert(FC.Queue.Accept(materialPlan, function() return copy(materialPlan) end))
local producer, parent = materialJob.tasks[2], materialJob.tasks[1]
producer.remainingExecutions = nil -- Saved jobs can predate the cached execution remainder.
assert(FC.Queue.Initialize(materialSave))
assert(FC.Queue.SetPaused(materialJob.id, true))
local needed = FC.Queue.GetCraftMaterialIDs()
assert(needed[200] and needed[8100] and needed[8101] and not needed[900] and not needed[100]
    and needed == FC.Queue.GetCraftMaterialIDs(), "accepted exact pending inputs stay protected while paused")
FC.state.characterKey = "actor-B"
assert(next(FC.Queue.GetCraftMaterialIDs()) == nil, "actor change invalidates the cached material set")
FC.state.characterKey = "actor-A"
assert(FC.Queue.SetPaused(materialJob.id, false))
assert(FC.Queue.Begin(materialJob, producer, {beforeOutput = 0, batch = 1}))
FC.Queue.CraftEvent(materialJob, producer, 1, 2)
assert(FC.Queue.Reconcile(materialJob, producer, 2))
needed = FC.Queue.GetCraftMaterialIDs()
assert(needed[200] and needed[8100] and not needed[8101], "only the unfinished parent keeps protection")
assert(FC.Queue.Begin(materialJob, parent, {beforeOutput = 0, batch = 1}))
FC.Queue.CraftEvent(materialJob, parent, 1, 1)
assert(FC.Queue.Reconcile(materialJob, parent, 1) and next(FC.Queue.GetCraftMaterialIDs()) == nil)

materialPlan.revision = "material-protection-clear"
local clearingMaterials = assert(FC.Queue.Accept(materialPlan, function() return copy(materialPlan) end))
assert(FC.Queue.Begin(clearingMaterials, clearingMaterials.tasks[2], {beforeOutput = 0, batch = 1}))
assert(FC.Queue.Clear() and FC.Queue.IsClearing(clearingMaterials))
needed = FC.Queue.GetCraftMaterialIDs()
assert(needed[8101] and not needed[8100] and not needed[200], "clearing protects only the issued task's inputs")
FC.Queue.MarkUncertain(clearingMaterials, clearingMaterials.tasks[2])
assert(FC.Queue.GetCraftMaterialIDs()[8101], "unreconciled exact inputs remain protected")
assert(FC.Queue.FinishDeferredInvalidation(clearingMaterials) and next(FC.Queue.GetCraftMaterialIDs()) == nil)

do
    local previousVersion, previousBuild = FC.version, FC.state.clientBuild
    FC.version, FC.state.clientBuild = "0.2.44-dev", 71037
    local recoverySave = {}
    assert(FC.Queue.Initialize(recoverySave))
    local fiveBags = plan(125)
    fiveBags.revision, fiveBags.rootRecipeId, fiveBags.rootItemID = "stopped-tailoring", 12079, 10051
    fiveBags.summary.requested = 5
    fiveBags.goal = {intent = "additional", destination = {actorKey = FC.state.characterKey, locationKey = "bags"}}
    fiveBags.tree.children[1].itemID = 4338
    local root, bolts = fiveBags.tasks[1], fiveBags.tasks[2]
    root.recipeId, root.outputItemID, root.executions, root.outputQuantity = 12079, 10051, 5, 5
    bolts.recipeId, bolts.professionId, bolts.outputItemID, bolts.yield = 3865, 197, 4339, 1
    bolts.executions, bolts.outputQuantity, bolts.inputs = 25, 25, {{itemID = 4338, quantity = 125}}
    local order = assert(FC.Queue.Accept(fiveBags, function() return copy(fiveBags) end))
    local bags, boltTask = order.tasks[1], order.tasks[2]
    local function beginBatch(batch, beforeOutput)
        assert(FC.Queue.Begin(order, boltTask, {batch = batch, beforeOutput = beforeOutput, maxYield = 1,
            recipeId = 3865, professionId = 197}))
    end
    beginBatch(12, 0)
    FC.Queue.CraftEvent(order, boltTask, 12, 12)
    assert(FC.Queue.Reconcile(order, boltTask, 12))
    beginBatch(13, 12)
    FC.Queue.MarkUncertain(order, boltTask, "The native craft stopped. Review any unconfirmed output.")
    local evidence = boltTask.evidence
    assert(evidence.sawCraftEvent == false and not evidence.carriedResult
        and FC.Queue.GetNativeReplanTask(order) == boltTask, "the stopped handoff can be replanned on 0.2.44")

    FC.version = "0.2.46-dev"
    assert(FC.Queue.Initialize(recoverySave))
    local interrupted = FC.L.execInterrupted
    FC.L.execInterrupted = "The craft stopped."
    local failed, pendingRoot = FC.Queue.GetNativeReplanTask(order)
    FC.L.execInterrupted = interrupted
    assert(failed == boltTask and pendingRoot == bags and boltTask.status == "uncertain"
        and boltTask.evidence == evidence and boltTask.completedExecutions == 12 and boltTask.remainingExecutions == 13
        and order.reservations["4338"] == 65 and order.producedReservations["4339"] == 12,
        "upgrading preserves eligibility for explicit recovery and never credits or replays unobserved work")
    FC.state.clientBuild = 71038
    assert(not FC.Queue.GetNativeReplanTask(order), "historical evidence still needs the same client build")
    FC.state.clientBuild, evidence.addonVersion = 71037, "0.2.43-dev"
    assert(not FC.Queue.GetNativeReplanTask(order), "other historical evidence formats remain ineligible")
    for _, version in ipairs({"0.2.45-dev", "0.2.46-dev", "0.2.47-dev"}) do
        evidence.addonVersion, evidence.dispatch = version, "process"
        assert(FC.Queue.GetNativeReplanTask(order) == boltTask,
            "a previously stopped direct Process attempt remains eligible for bags recovery")
    end
    evidence.dispatch = "other"
    assert(not FC.Queue.GetNativeReplanTask(order), "an unrecognized historical dispatch mode remains ineligible")
    FC.version, FC.state.clientBuild = previousVersion, previousBuild
end

do
    local previousVersion, previousBuild = FC.version, FC.state.clientBuild
    FC.version, FC.state.clientBuild = "0.2.46-dev", 71037
    local interruptedSave = {}
    assert(FC.Queue.Initialize(interruptedSave))
    local interruptedPlan = plan(4)
    local order = assert(FC.Queue.Accept(interruptedPlan, function() return copy(interruptedPlan) end))
    local current = order.tasks[2]
    local context = {batch = 1, beforeOutput = 12, recipeId = current.recipeId, professionId = current.professionId}
    assert(FC.Queue.Begin(order, current, context))
    local stopped = current.evidence
    stopped.interruptedCastGUID = "Cast-exact-interruption"
    assert(not FC.Queue.ResumeInterrupted(order, current, copy(stopped)), "only the active journal may return to Queue")
    assert(FC.Queue.ResumeInterrupted(order, current, stopped, "interrupted"))
    assert(order.status == "queued" and current.status == "pending" and not current.evidence
        and order.reservations["100"] == 4 and current.remainingExecutions == 1 and current.completedExecutions == 0)
    assert(FC.Queue.Initialize(interruptedSave))
    local archived = current.interruptedAttempts[1]
    assert(FC.Queue.GetJob(order.id) == order and FC.Queue.CanProcess(order, current)
        and archived.evidence.interruptedCastGUID == "Cast-exact-interruption" and archived.reason == "interrupted",
        "the same pending operation and its stopped history survive a reload")
    assert(FC.Queue.Begin(order, current, context))
    assert(not FC.Queue.ResumeInterrupted(order, current, stopped), "old cancellation cannot end a new submission")
    FC.Queue.CraftEvent(order, current, 1, 2)
    assert(not FC.Queue.ResumeInterrupted(order, current, current.evidence), "a matched craft must reconcile normally")
    assert(FC.Queue.Reconcile(order, current, 14) and #current.interruptedAttempts == 1
        and current.completedExecutions == 1 and order.tasks[1].status == "pending")
    FC.version, FC.state.clientBuild = previousVersion, previousBuild
end

print("queue tests passed")
