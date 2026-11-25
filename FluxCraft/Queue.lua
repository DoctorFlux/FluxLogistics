local _, FC = ...

local Queue = {}
FC.Queue = Queue
local state
local craftMaterialCache
local unprovedBeforeRecovery = "No matching output was recorded during the craft. Use X on this job before requeuing any remaining work."

local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, child in pairs(value) do result[key] = copy(child) end
    return result
end

local function changed()
    if state then state.revision = (state.revision or 0) + 1 end
    if type(FC.Emit) == "function" then FC:Emit("QUEUE_CHANGED") end
end

function Queue.GetRevision() return state and state.revision or 0 end

local function isOpen(job)
    return job.status ~= "complete" and job.status ~= "cancelled" and job.status ~= "replaced"
end

function Queue.IsClearing(job)
    return job ~= nil and isOpen(job) and job.clearRequested == true
end

function Queue.GetAcquisition(job, index)
    local primary = job and job.acquisition
    if index == nil or primary and primary.index == index then return primary end
    return job and job.vendorAcquisitions and job.vendorAcquisitions[index]
end

function Queue.Acquisitions(job)
    local actions = {}
    if job and job.vendorAcquisitions then
        for _, action in pairs(job.vendorAcquisitions) do actions[#actions + 1] = action end
        table.sort(actions, function(left, right) return left.index < right.index end)
    end
    if job and job.acquisition then table.insert(actions, 1, job.acquisition) end
    return actions
end

local function promoteAcquisition(job)
    if job.acquisition or not job.vendorAcquisitions then return end
    local first
    for index in pairs(job.vendorAcquisitions) do
        if not first or index < first then first = index end
    end
    if first then
        job.acquisition = job.vendorAcquisitions[first]
        job.vendorAcquisitions[first] = nil
    end
    if not next(job.vendorAcquisitions) then job.vendorAcquisitions = nil end
end

-- Bank and auction actions retain their exclusive job slot. A merchant pass
-- may journal several unrelated SKUs under the same accepted craft order.
function Queue.AddVendorAcquisition(job, action)
    if not job or job.status ~= "queued" or not action or action.kind ~= "vendor"
        or action.status ~= "issued" or Queue.IsClearing(job) then return false end
    local requirement = job.requirements and job.requirements[action.index]
    if not requirement or not requirement.itemID or Queue.GetAcquisition(job, action.index) then return false end
    for _, existing in ipairs(Queue.Acquisitions(job)) do
        local other = job.requirements[existing.index]
        if existing.kind ~= "vendor" or existing.status ~= "issued" or existing.dispatching
            or not other or tostring(other.itemID) == tostring(requirement.itemID) then return false end
    end
    if job.acquisition then
        job.vendorAcquisitions = job.vendorAcquisitions or {}
        job.vendorAcquisitions[action.index] = action
    else
        job.acquisition = action
    end
    return true
end

function Queue.RemoveAcquisition(job, action)
    if not job or not action or Queue.GetAcquisition(job, action.index) ~= action then return false end
    if job.acquisition == action then
        job.acquisition = nil
        promoteAcquisition(job)
    else
        job.vendorAcquisitions[action.index] = nil
        if not next(job.vendorAcquisitions) then job.vendorAcquisitions = nil end
    end
    return true
end

function Queue.HasIssuedAcquisition(job)
    if job and job.acquisition and job.acquisition.status == "issued" then return true end
    for _, action in pairs(job and job.vendorAcquisitions or {}) do
        if action.status == "issued" then return true end
    end
    return false
end

local function sameChoices(left, right)
    if left == right then return true end
    if type(left) ~= "table" or type(right) ~= "table" then return false end
    for key, value in pairs(left) do
        if not sameChoices(value, right[key]) then return false end
    end
    for key in pairs(right) do
        if left[key] == nil then return false end
    end
    return true
end

local function recipeAssignment(task)
    local inputs = {}
    for _, input in ipairs(task.inputs or {}) do
        if type(input.quantity) ~= "number" then return end
        inputs[#inputs + 1] = table.concat({tostring(input.itemID), tostring(input.quantity / task.executions),
            tostring(input.slotIndex or input.reagentSlotIndex), tostring(input.itemLink)}, ":")
    end
    table.sort(inputs)
    return table.concat({tostring(task.recipeId), tostring(task.recipeRevision), tostring(task.professionId),
        tostring(task.yield), tostring(task.yieldMax or task.yield), table.concat(inputs, ",")}, "|")
end

local function recipeAssignments(job)
    local result = {}
    for _, task in ipairs(job.tasks or {}) do
        if task.outputItemID and type(task.executions) == "number" and task.executions > 0 then
            local key = recipeAssignment(task)
            if not key then return end
            local assignments = result[task.outputItemID] or {}
            result[task.outputItemID] = assignments
            assignments[key] = true
        end
    end
    return result
end

function Queue.SameCraft(left, right)
    if left.outputItemID ~= right.outputItemID then return false end
    local assignment = recipeAssignment(left)
    return assignment ~= nil and assignment == recipeAssignment(right)
end

-- Groups are for display only. Orders, spending limits and receipts belong
-- to the independently accepted jobs.
function Queue.CanGroup(left, right)
    if not left or not right or not left.rootRecipeId or left.rootRecipeId ~= right.rootRecipeId
        or left.rootItemID ~= right.rootItemID or left.characterKey ~= right.characterKey or left.build ~= right.build then
        return false
    end
    local a, b = left.goal or {}, right.goal or {}
    local destinationA, destinationB = a.destination or {}, b.destination or {}
    if (a.intent or a.type or "additional") ~= (b.intent or b.type or "additional")
        or a.demandId ~= b.demandId
        or (destinationA.actorKey or left.characterKey) ~= (destinationB.actorKey or right.characterKey)
        or (destinationA.locationKey or "bags") ~= (destinationB.locationKey or "bags")
        or not sameChoices(a.sourceChoices or {}, b.sourceChoices or {})
        or not sameChoices(a.auctionOnly or {}, b.auctionOnly or {}) then return false end
    local choicesA, choicesB = recipeAssignments(left), recipeAssignments(right)
    if not choicesA or not choicesB or not choicesA[left.rootItemID] or not choicesB[right.rootItemID] then return false end
    for itemID, assignments in pairs(choicesA) do
        if choicesB[itemID] and not sameChoices(assignments, choicesB[itemID]) then return false end
    end
    return true
end

local function addCount(counts, itemID, quantity)
    local key = tostring(itemID)
    local total = (counts[key] or 0) + quantity
    counts[key] = total > 0 and total or nil
end

local function signature(plan)
    if type(plan) ~= "table" then return nil end
    local parts = {tostring(plan.revision), tostring(plan.rootRecipeId), tostring(plan.status)}
    for _, task in ipairs(plan.tasks or {}) do
        parts[#parts + 1] = table.concat({tostring(task.taskId), tostring(task.recipeId),
            tostring(task.professionId), tostring(task.outputItemID), tostring(task.executions)}, ":")
        local deps = copy(task.dependencies or {})
        table.sort(deps)
        parts[#parts + 1] = table.concat(deps, ",")
        for _, input in ipairs(task.inputs or {}) do
            parts[#parts + 1] = table.concat({tostring(input.itemID), tostring(input.quantity),
                tostring(input.slotIndex or input.reagentSlotIndex), tostring(input.itemLink)}, ":")
        end
        for _, allocation in ipairs(task.allocations or {}) do
            parts[#parts + 1] = table.concat({tostring(allocation.kind), tostring(allocation.itemID),
                tostring(allocation.quantity), tostring(allocation.requirementId),
                tostring(allocation.producerTaskId), tostring(allocation.locationKey)}, ":")
        end
    end
    for _, requirement in ipairs(plan.requirements or {}) do
        parts[#parts + 1] = table.concat({tostring(requirement.itemID), tostring(requirement.quantity),
            tostring(requirement.kind), tostring(requirement.offerId), tostring(requirement.source),
            tostring(requirement.requirementId)}, "=")
    end
    local function walk(node)
        if not node then return end
        parts[#parts + 1] = table.concat({tostring(node.itemID), tostring(node.required),
            tostring(node.source), tostring(node.recipeId), tostring(node.ownedUsed),
            tostring(node.buy), tostring(node.craftCount)}, ":")
        for _, child in ipairs(node.children or {}) do walk(child) end
    end
    walk(plan.tree)
    local goal = plan.goal or {}
    local destination = type(goal.destination) == "table" and goal.destination or {}
    parts[#parts + 1] = table.concat({tostring(goal.intent), tostring(goal.quantity),
        tostring(goal.demandId), tostring(destination.actorKey), tostring(destination.locationKey)}, ":")
    return table.concat(parts, "|")
end

local function ownedAllocations(tree, into)
    if not tree then return into end
    if tree.itemID and type(tree.ownedUsed) == "number" and tree.ownedUsed > 0 then
        local key = tostring(tree.itemID)
        into[key] = (into[key] or 0) + tree.ownedUsed
    end
    for _, child in ipairs(tree.children or {}) do ownedAllocations(child, into) end
    return into
end

function Queue.AcquisitionRemaining(job, requirement)
    local remainder = requirement.remaining or requirement.quantity
    if requirement.kind ~= "vendor" then return remainder, remainder end

    local allocated
    if job.allocations and requirement.requirementId then
        for _, allocation in ipairs(job.allocations) do
            if allocation.requirementId == requirement.requirementId then
                allocated = (allocated or 0) + allocation.quantity
            end
        end
    end
    -- The vendor quote can include a whole-bundle surplus. Only the units
    -- actually allocated to this goal or a craft are necessary for readiness.
    local needed = math.min(allocated or requirement.quantity, requirement.quantity)
    needed = math.max(0, needed - (requirement.quantity - remainder))
    local quote = requirement.offer or requirement.quote or requirement
    local bundle = type(quote.bundleSize) == "number" and quote.bundleSize >= 1 and quote.bundleSize or 1
    return needed, math.ceil(needed / bundle) * bundle
end

local function settle(job)
    for _, task in ipairs(job.tasks) do
        if task.status ~= "complete" then return end
    end
    for _, requirement in ipairs(job.requirements or {}) do
        if Queue.AcquisitionRemaining(job, requirement) > 0 then return end
    end
    local goal = job.goal
    local destination = goal and goal.destination
    if goal and goal.intent == "delivery" and (type(destination) ~= "table"
        or destination.actorKey ~= job.characterKey or destination.locationKey ~= "bags") then
        job.status = "awaiting_delivery"
        return
    end
    job.status = "complete"
    job.reservations, job.producedReservations = {}, {}
end

local function releaseAuctionReceipts(job)
    for _, requirement in ipairs(job.requirements or {}) do
        if (requirement.auctionAwaiting or 0) > 0 then
            job.auctionReceiptsReleased = true
            return
        end
    end
end

local function cancel(job)
    if job.status ~= "invalidated" then releaseAuctionReceipts(job) end
    job.status, job.reservations, job.producedReservations = "cancelled", {}, {}
    job.clearRequested = nil
end

local function cancellationBlocker(job)
    for _, task in ipairs(job.tasks or {}) do
        if task.status == "in_flight" then
            return FC.L and FC.L.queueCancelCraft or "Wait for the active craft before cancelling its job."
        end
    end
    if Queue.HasIssuedAcquisition(job) then
        return FC.L and FC.L.queueCancelAcquisition or "Reconcile the active acquisition before cancelling its job."
    end
end

local function settleClearing(job)
    if not Queue.IsClearing(job) or cancellationBlocker(job) then return false end
    job.clearRequested = nil
    settle(job)
    if isOpen(job) then cancel(job) end
    return true
end

local function settleQuietClear(job)
    if not Queue.IsClearing(job) or cancellationBlocker(job) then return false end
    if job.status == "uncertain" then
        for _, task in ipairs(job.tasks or {}) do
            if task.status == "uncertain" and (Queue.Reconcile(job, task) or Queue.ReconcilePartial(job, task)) then
                return true
            end
        end
    end
    return settleClearing(job)
end

local unlearned = "Recipe was unlearned. Explicitly replan from fresh recipe data."

local function invalidate(job, reason)
    local deferred = job.invalidatedAfterAction
    job.invalidationReason = reason or type(deferred) == "string" and deferred or unlearned
    job.status = "invalidated"
    job.invalidatedAfterAction = nil
    job.invalidatedActiveTask, job.invalidatedActiveReason = nil, nil
    job.reservations, job.producedReservations = {}, {}
    releaseAuctionReceipts(job)
end

local function settleDeferredInvalidation(job)
    if settleClearing(job) then return true end
    if not isOpen(job) or job.status == "invalidated" or not job.invalidatedAfterAction
        or job.acquisition or job.status == "running" or job.status == "uncertain" then return false end
    invalidate(job)
    return true
end

function Queue.FinishDeferredInvalidation(job)
    if job and Queue.GetJob(job.id) == job and settleDeferredInvalidation(job) then
        changed()
        return true
    end
    return false
end

local function settleAfterCraft(job, task)
    if job.invalidatedActiveTask == task.taskId and task.status ~= "complete" then
        task.blocker = job.invalidatedActiveReason or unlearned
        job.invalidatedAfterAction = job.invalidatedAfterAction or task.blocker
    end
    job.invalidatedActiveTask, job.invalidatedActiveReason = nil, nil
    if not settleDeferredInvalidation(job) then settle(job) end
end

function Queue.Initialize(charDB)
    if type(charDB) ~= "table" then return false, "Character SavedVariables are unavailable." end
    local build = tostring(FC.state and FC.state.build or "unknown")
    charDB.queueByBuild = charDB.queueByBuild or {}
    state = charDB.queueByBuild[build]
    if type(state) ~= "table" then
        state = {jobs = {}, nextId = 1, build = build}
        charDB.queueByBuild[build] = state
    end
    state.jobs = state.jobs or {}
    state.nextId = tonumber(state.nextId) or 1
    for _, job in ipairs(state.jobs) do
        job.reservations = job.reservations or {}
        job.producedReservations = job.producedReservations or {}
        promoteAcquisition(job)
        for _, action in ipairs(Queue.Acquisitions(job)) do
            action.dispatching = nil
            if action.status == "issued" then action.status = "uncertain" end
        end
        if job.status == "running" then job.status = "uncertain" end
        for _, task in ipairs(job.tasks or {}) do
            if task.status == "in_flight" then
                task.status = "uncertain"
                task.blocker = "Craft outcome needs reconciliation after reload."
                job.status = "uncertain"
            end
        end
    end
    for _, job in ipairs(state.jobs) do settleQuietClear(job) end
    changed()
    return true
end

function Queue.GetJobs()
    return state and state.jobs or {}
end

-- The set belongs to the queue. Consumers may read its numeric item IDs.
function Queue.GetCraftMaterialIDs()
    local actor = FC.state and FC.state.characterKey
    local build = tostring(FC.state and FC.state.build)
    local revision = Queue.GetRevision()
    local cached = craftMaterialCache
    if cached and cached.state == state and cached.revision == revision and cached.actor == actor and cached.build == build then
        return cached.items
    end

    local items = {}
    for _, job in ipairs(Queue.GetJobs()) do
        if actor and job.characterKey == actor and job.build == build and (job.status == "queued"
            or job.status == "running" or job.status == "paused" or job.status == "uncertain") then
            local activeOnly = Queue.IsClearing(job) or job.invalidatedAfterAction
            for _, task in ipairs(job.tasks or {}) do
                local remaining = task.remainingExecutions or (task.executions or 0) - (task.completedExecutions or 0)
                if remaining > 0 and (not task.actorKey or task.actorKey == actor)
                    and (task.status == "in_flight" or task.status == "uncertain" or task.status == "pending" and not activeOnly) then
                    for _, input in ipairs(task.inputs or {}) do
                        local itemID = tonumber(input.itemID)
                        if itemID and itemID > 0 and itemID < math.huge and itemID % 1 == 0
                            and (tonumber(input.quantity) or 0) > 0 then items[itemID] = true end
                    end
                end
            end
        end
    end
    craftMaterialCache = {state = state, revision = revision, actor = actor, build = build, items = items}
    return items
end

function Queue.Reserved(exceptJob, batchOrders)
    local reserved = {}
    if not state then return reserved end
    for _, job in ipairs(state.jobs) do
        if job ~= exceptJob and not (batchOrders and batchOrders[job]) and isOpen(job) then
            for itemID, count in pairs(job.reservations or {}) do
                reserved[itemID] = (reserved[itemID] or 0) + count
            end
            for itemID, count in pairs(job.producedReservations or {}) do
                reserved[itemID] = (reserved[itemID] or 0) + count
            end
        end
    end
    return reserved
end

function Queue.AvailableCount(itemID, physicalCount, job)
    return math.max(0, physicalCount - (Queue.Reserved(job)[tostring(itemID)] or 0))
end

function Queue.AvailableInventory(counts, exceptJob, batchOrders)
    local result = copy(counts or {})
    for itemID, count in pairs(Queue.Reserved(exceptJob, batchOrders)) do
        local numeric = tonumber(itemID)
        local current = result[numeric] or result[itemID] or 0
        result[numeric or itemID] = math.max(0, current - count)
        if numeric then result[itemID] = nil end
    end
    return result
end

function Queue.CanReplace(job)
    if not job or Queue.GetJob(job.id) ~= job or not isOpen(job)
        or Queue.IsClearing(job)
        or job.status == "uncertain" or job.status == "running" or job.status == "awaiting_delivery"
        or job.acquisition then return false end
    for _, requirement in ipairs(job.requirements or {}) do
        if (requirement.auctionAwaiting or 0) > 0 then return false, "reviseAfterDelivery" end
    end
    return true
end

local function batchable(job)
    local goal = job and job.goal
    local destination = goal and goal.destination
    if not job or job.status ~= "queued" or not job.rootRecipeId or job.characterKey ~= FC.state.characterKey
        or job.build ~= tostring(FC.state.build) or not goal or goal.intent ~= "additional" or goal.demandId
        or not destination or destination.actorKey ~= job.characterKey or destination.locationKey ~= "bags"
        or job.invalidatedAfterAction or job.invalidatedActiveTask
        or not Queue.CanReplace(job) or Queue.OutstandingOutput(job) <= 0 then return false end
    for _, requirement in ipairs(job.requirements or {}) do
        if Queue.AcquisitionRemaining(job, requirement) > 0 then return false end
    end
    return true
end

function Queue.GetBatchOrders(job)
    if not batchable(job) then return end
    local orders = {}
    local hasPrerequisites
    for _, candidate in ipairs(state.jobs) do
        if candidate == job or Queue.CanGroup(job, candidate) and batchable(candidate) then
            local compatible = true
            for _, member in ipairs(orders) do
                if not Queue.CanGroup(member, candidate) then compatible = false; break end
            end
            if compatible then
                orders[#orders + 1] = candidate
                hasPrerequisites = hasPrerequisites or #candidate.tasks > 1
            end
        end
    end
    if hasPrerequisites and #orders > 1 then return orders end
end

-- Rebuild only the outstanding work. Carried intermediates can replace
-- producer crafts, but each final recipe and reagent assignment stays bounded.
function Queue.MatchesBatchPlan(plan, orders)
    if not plan or plan.status ~= "ready" or #(plan.requirements or {}) > 0
        or not orders or #orders < 2 or not plan.goal or plan.goal.intent ~= "additional"
        or plan.goal.demandId or plan.goal.autoBuyVendor ~= false then return false end
    local destination = plan.goal.destination
    if not destination or destination.actorKey ~= FC.state.characterKey or destination.locationKey ~= "bags" then
        return false
    end
    local available, included = {}, {}
    local quantity, rootExecutions = 0, 0
    for index, job in ipairs(orders) do
        if included[job] or not batchable(job)
            or job.rootRecipeId ~= plan.rootRecipeId or job.rootItemID ~= plan.rootItemID then return false end
        for earlier = 1, index - 1 do
            if not Queue.CanGroup(job, orders[earlier]) then return false end
        end
        included[job] = true
        quantity = quantity + Queue.OutstandingOutput(job)
        for _, task in ipairs(job.tasks) do
            local key = recipeAssignment(task)
            if not key then return false end
            local remaining = task.remainingExecutions or task.executions - (task.completedExecutions or 0)
            available[key] = (available[key] or 0) + remaining
            if task.recipeId == job.rootRecipeId then rootExecutions = rootExecutions + remaining end
        end
    end
    if not plan.summary or plan.summary.requested ~= quantity then return false end
    local plannedRoot = 0
    for _, task in ipairs(plan.tasks or {}) do
        local key = recipeAssignment(task)
        if not key or task.executions > (available[key] or 0) then return false end
        available[key] = available[key] - task.executions
        if task.recipeId == plan.rootRecipeId then plannedRoot = plannedRoot + task.executions end
    end
    return plannedRoot > 0 and plannedRoot == rootExecutions
end

function Queue.GetNativeReplanTask(job)
    if FC.target ~= "forever" or not job or Queue.GetJob(job.id) ~= job or job.status ~= "uncertain"
        or Queue.IsClearing(job) or job.acquisition or job.invalidatedAfterAction or job.invalidatedActiveTask
        or job.characterKey ~= FC.state.characterKey or tostring(job.build) ~= tostring(FC.state.build) then return end
    local goal = job.goal
    local destination = goal and goal.destination
    if not goal or goal.intent ~= "additional" or goal.demandId or not destination
        or destination.actorKey ~= job.characterKey or destination.locationKey ~= "bags" then return end
    -- Historical settled purchases stay on the archived job. No unfinished
    -- acquisition or incoming delivery can move to a bags-only replacement.
    for _, requirement in ipairs(job.requirements or {}) do
        if requirement.remaining ~= 0 or (requirement.auctionAwaiting or 0) ~= 0 then return end
    end

    local failed, root
    for _, task in ipairs(job.tasks or {}) do
        if task.status == "uncertain" then
            if failed then return end
            failed = task
        elseif task.status == "in_flight" then return
        elseif task.recipeId == job.rootRecipeId and task.outputItemID == job.rootItemID then
            if root or task.status ~= "pending" or (task.completedExecutions or 0) ~= 0 then return end
            root = task
        end
    end
    local evidence = failed and failed.evidence
    -- Keep prior native handoff and direct Process evidence usable after upgrading.
    local version = evidence and evidence.addonVersion
    local legacyNativeEvidence = evidence and (
        version == "0.2.44-dev" and evidence.dispatch == nil
        or (version == "0.2.45-dev" or version == "0.2.46-dev" or version == "0.2.47-dev"
            or version == "0.2.48-dev" or version == "0.2.49-dev" or version == "0.2.50-dev"
            or version == "0.2.51-dev" or version == "0.2.52-dev" or version == "0.2.53-dev"
            or version == "0.2.54-dev" or version == "0.2.55-dev" or version == "0.2.56-dev"
            or version == "0.2.57-dev" or version == "0.2.58-dev" or version == "0.2.59-dev"
            or version == "0.2.60-dev" or version == "0.2.61-dev" or version == "0.2.62-dev"
            or version == "0.2.63-dev" or version == "0.2.64-dev" or version == "0.2.65-dev"
            or version == "0.2.66-dev" or version == "0.2.67-dev" or version == "0.2.68-dev"
            or version == "0.2.69-dev" or version == "0.2.70-dev")
        and (evidence.dispatch == nil or evidence.dispatch == "process"))
    if not root or not evidence or failed.outputItemID == job.rootItemID
        or not FC.version or (tostring(evidence.addonVersion) ~= tostring(FC.version) and not legacyNativeEvidence)
        or not FC.state.clientBuild or tostring(evidence.clientBuild) ~= tostring(FC.state.clientBuild)
        or evidence.recipeId ~= failed.recipeId or evidence.professionId ~= failed.professionId
        or type(evidence.batch) ~= "number" or evidence.batch < 1 or evidence.batch % 1 ~= 0
        or evidence.maxYield ~= failed.yield or type(evidence.beforeOutput) ~= "number" then return end
    if failed.blocker ~= FC.L.execTimedOut and failed.blocker ~= FC.L.execInterrupted
        and failed.blocker ~= FC.L.execUnproved and failed.blocker ~= unprovedBeforeRecovery
        and not (legacyNativeEvidence and failed.blocker == "The native craft stopped. Review any unconfirmed output.")
        and failed.blocker ~= "Craft outcome needs reconciliation after reload." then return end
    for _, dependency in ipairs(root.dependencies or {}) do
        if dependency == failed.taskId then return failed, root end
    end
end

local function recoveryMatches(plan, job, task)
    local current, root = Queue.GetNativeReplanTask(job)
    if not current or current ~= task or not plan or plan.status ~= "ready" or #(plan.requirements or {}) ~= 0
        or plan.rootRecipeId ~= job.rootRecipeId or plan.rootItemID ~= job.rootItemID
        or not plan.summary or plan.summary.requested ~= Queue.OutstandingOutput(job) then return false end
    local goal = plan.goal
    local destination = goal and goal.destination
    if not goal or goal.intent ~= "additional" or goal.demandId or goal.autoBuyVendor ~= false
        or not destination or destination.actorKey ~= job.characterKey or destination.locationKey ~= "bags" then
        return false
    end
    for _, replacement in ipairs(plan.tasks or {}) do
        if replacement.recipeId == root.recipeId and replacement.outputItemID == root.outputItemID
            and replacement.yield == root.yield and replacement.professionId == root.professionId
            and replacement.executions == root.remainingExecutions then return true end
    end
    return false
end

local function acceptPlan(plan, revalidate, replaces, recovery, batch)
    if not state then return nil, "Queue is not initialized." end
    if not plan or (plan.status ~= "ready" and plan.status ~= "sourcing") then
        return nil, "The selected plan is blocked."
    end
    if batch and not Queue.MatchesBatchPlan(plan, batch) then return nil, FC.L.execMissingMaterials end
    if replaces then
        local canReplace, reason
        if recovery then canReplace = recoveryMatches(plan, replaces, recovery)
        else canReplace, reason = Queue.CanReplace(replaces) end
        if not canReplace or plan.rootItemID ~= replaces.rootItemID then
            return nil, reason and FC.L and FC.L[reason]
                or "Review the job and its active operations before revising remaining work."
        end
    end
    if type(revalidate) ~= "function" then return nil, "A fresh plan check is required." end
    local planSignature = signature(plan)
    for _, job in ipairs(state.jobs) do
        if job ~= replaces and job.planSignature == planSignature then
            return nil, "This preview was already accepted. Make a new preview to create another job."
        end
    end
    local fresh = revalidate()
    if signature(fresh) ~= planSignature or recovery and not recoveryMatches(fresh, replaces, recovery)
        or batch and not Queue.MatchesBatchPlan(fresh, batch) then
        return nil, "Recipe, inventory, price or route changed. Preview the revised plan first."
    end
    local tasks = copy(plan.tasks or {})
    if #tasks == 0 and #(plan.requirements or {}) == 0 and #(plan.allocations or {}) == 0 then
        return nil, "There is no outstanding work to queue."
    end
    local id = state.nextId
    local job = {id = id, characterKey = FC.state.characterKey, build = state.build,
        rootRecipeId = plan.rootRecipeId, rootItemID = plan.rootItemID,
        planRevision = plan.revision, planSignature = planSignature, status = "queued",
        goal = copy(plan.goal or {}), tree = copy(plan.tree), allocations = copy(plan.allocations),
        tasks = tasks, requirements = copy(plan.requirements or {}),
        summary = copy(plan.summary), reservations = ownedAllocations(plan.tree, {}),
        producedReservations = {}, createdAt = type(time) == "function" and time() or 0}
    for _, task in ipairs(job.tasks) do
        task.status = "pending"
        task.remainingExecutions = task.executions
        task.completedExecutions = 0
    end
    for index, requirement in ipairs(job.requirements) do
        requirement.id = index
        requirement.remaining = requirement.quantity
        if requirement.kind == "vendor" then
            requirement.vendorIssuedUnits, requirement.vendorIssuedCopper = 0, 0
        end
        requirement.baseline = FC.InventoryAdapter and FC.InventoryAdapter.Count(requirement.itemID)
    end
    local insertAt = #state.jobs + 1
    if batch then
        -- Preserve queue order and keep the original orders and receipts in the journal.
        for index, candidate in ipairs(state.jobs) do
            if candidate == batch[1] then insertAt = index; break end
        end
        job.replaces = batch[1].id
        for _, member in ipairs(batch) do
            member.status, member.replacement = "replaced", job.id
            member.reservations, member.producedReservations = {}, {}
        end
    end
    table.insert(state.jobs, insertAt, job)
    state.nextId = id + 1
    if replaces then
        job.replaces = replaces.id
        replaces.status, replaces.replacement = "replaced", job.id
        replaces.reservations, replaces.producedReservations = {}, {}
    end
    settle(job)
    changed()
    return job
end

function Queue.Accept(plan, revalidate, replaces)
    return acceptPlan(plan, revalidate, replaces)
end

function Queue.AcceptNativeReplan(plan, revalidate, job, task)
    if not job or not task then return end
    return acceptPlan(plan, revalidate, job, task)
end

function Queue.AcceptBatch(plan, revalidate, orders)
    if not orders then return end
    return acceptPlan(plan, revalidate, nil, nil, orders)
end

local function taskMap(job)
    local map = {}
    for _, task in ipairs(job.tasks or {}) do map[task.taskId] = task end
    return map
end

function Queue.AreJobInputsCarried(job, countItem)
    if not job or job.status ~= "queued" or job.acquisition or Queue.IsClearing(job) then return false end
    for _, requirement in ipairs(job.requirements or {}) do
        if Queue.AcquisitionRemaining(job, requirement) > 0 or (requirement.auctionAwaiting or 0) > 0 then return false end
    end

    local byID, pending, future = taskMap(job), {}, {}
    for _, task in ipairs(job.tasks or {}) do
        if task.status == "pending" then
            local remaining = task.remainingExecutions or task.executions
            if type(remaining) ~= "number" or type(task.executions) ~= "number" or remaining < 1
                or remaining > task.executions or remaining % 1 ~= 0 or type(task.yield) ~= "number"
                or task.yield < 1 or task.yield % 1 ~= 0 then return false end
            pending[task], future[task.taskId] = remaining, remaining * task.yield
        elseif task.status ~= "complete" then
            return false
        end
    end

    local needed = {}
    for _, task in ipairs(job.tasks or {}) do
        if pending[task] then
            local inputs = {}
            for _, input in ipairs(task.inputs or {}) do
                local itemID = tonumber(input.itemID)
                local perCraft = type(input.quantity) == "number" and input.quantity / task.executions
                if not itemID or itemID <= 0 or itemID % 1 ~= 0 or not perCraft or perCraft < 1
                    or perCraft % 1 ~= 0 then return false end
                inputs[itemID] = (inputs[itemID] or 0) + perCraft * pending[task]
            end
            local promised = {}
            for _, allocation in ipairs(task.allocations or {}) do
                if allocation.producerTaskId then
                    local producer = byID[allocation.producerTaskId]
                    if not producer or tonumber(producer.outputItemID) ~= tonumber(allocation.itemID)
                        or type(allocation.quantity) ~= "number" or allocation.quantity < 1
                        or allocation.quantity % 1 ~= 0 then return false end
                    promised[producer] = (promised[producer] or 0) + allocation.quantity
                end
            end
            for _, id in ipairs(task.dependencies or {}) do
                local producer = byID[id]
                if not producer or producer == task then return false end
                if pending[producer] then
                    local itemID = tonumber(producer.outputItemID)
                    local quantity = inputs[itemID] or 0
                    local assigned = task.allocations and (promised[producer] or 0) or quantity
                    local made = math.min(assigned, quantity, future[id])
                    if made > 0 then
                        inputs[itemID], future[id] = quantity - made, future[id] - made
                    end
                end
            end
            for itemID, quantity in pairs(inputs) do needed[itemID] = (needed[itemID] or 0) + quantity end
        end
    end
    local reserved = Queue.Reserved(job)
    for itemID, quantity in pairs(needed) do
        if quantity > 0 then
            local carried = countItem(itemID)
            if (issecretvalue and issecretvalue(carried)) or type(carried) ~= "number"
                or carried < quantity + (reserved[tostring(itemID)] or 0) then return false end
        end
    end
    return true
end

local function acquiredAllocations(task)
    local totals = {}
    for _, allocation in ipairs(task.allocations or {}) do
        if allocation.requirementId then addCount(totals, allocation.requirementId, allocation.quantity) end
    end
    return totals
end

local function inputUnits(task, itemID)
    local total = 0
    local key = tostring(itemID)
    for _, input in ipairs(task.inputs) do
        if tostring(input.itemID) == key then total = total + input.quantity end
    end
    return total
end

local function hasAcquiredInputs(job, task)
    local planned = acquiredAllocations(task)
    if not next(planned) then return true end
    local open, needed, items = {}, {}, {}
    for _, requirement in ipairs(job.requirements or {}) do
        local id = requirement.requirementId
        if planned[id] then
            if Queue.AcquisitionRemaining(job, requirement) > 0 then
                open[id], needed[id] = requirement, planned[id]
                items[tostring(requirement.itemID)] = requirement.itemID
            end
            planned[id] = nil
        end
    end
    if next(planned) then return false end
    if not next(open) then return true end
    if not job.allocations or not task.inputs or not task.executions or task.executions < 1 then return false end

    -- A receipt covers this task's lifetime allocation and any share already
    -- used by siblings. For a partial sibling batch, charge up to its confirmed
    -- consumption of that ingredient because the physical units are fungible.
    for _, sibling in ipairs(job.tasks or {}) do
        local completed = sibling.completedExecutions or 0
        if sibling ~= task and completed > 0 then
            if not sibling.allocations or not sibling.inputs or not sibling.executions
                or sibling.executions < completed then return false end
            local used = acquiredAllocations(sibling)
            for id, requirement in pairs(open) do
                if used[id] then
                    local consumed = inputUnits(sibling, requirement.itemID) / sibling.executions * completed
                    needed[id] = needed[id] + math.min(used[id], consumed)
                end
            end
        end
    end
    for id, requirement in pairs(open) do
        local credited = requirement.quantity - (requirement.remaining or requirement.quantity)
        if credited < needed[id] then return false end
    end

    local remaining = task.remainingExecutions or task.executions
    for key, itemID in pairs(items) do
        local neededUnits = inputUnits(task, itemID) / task.executions * remaining
        local reserved = (job.reservations[key] or 0) + (job.producedReservations[key] or 0)
        if neededUnits <= 0 or reserved < neededUnits then return false end
    end
    return true
end

local function dependenciesComplete(job, task)
    local byId = taskMap(job)
    if byId[task.taskId] ~= task then return false end
    for _, dependency in ipairs(task.dependencies or {}) do
        if not byId[dependency] or byId[dependency].status ~= "complete" then return false end
    end
    return true
end

function Queue.IsFinalCraftReady(job, task)
    if not job or not task or job.acquisition or task.status ~= "pending"
        or task.recipeId ~= job.rootRecipeId or task.outputItemID ~= job.rootItemID then return false end
    for _, candidate in ipairs(job.tasks or {}) do
        if candidate ~= task and candidate.status ~= "complete" then return false end
    end
    return dependenciesComplete(job, task)
end

function Queue.CraftExecutionLimit(job, task)
    local remaining = task.remainingExecutions or task.executions
    if hasAcquiredInputs(job, task) then return remaining end
    local singleCreate = job.goal and job.goal.createOnQueue and #job.tasks == 1 and job.tasks[1] == task
    if not (singleCreate or Queue.IsFinalCraftReady(job, task)) or not task.inputs or #task.inputs == 0 then return 0 end

    -- Once the final craft is the only work left, use its carried allocation
    -- first and leave the accepted acquisitions for any remaining quantity.
    local materials = {}
    for _, input in ipairs(task.inputs) do addCount(materials, input.itemID, input.quantity) end
    for itemID, quantity in pairs(materials) do
        local allocated = (job.reservations[itemID] or 0) + (job.producedReservations[itemID] or 0)
        remaining = math.min(remaining, math.floor(allocated / (quantity / task.executions)))
    end
    return remaining
end

function Queue.CanPrepareCraft(job, task)
    return not not (job and task and task.status == "pending" and not job.invalidatedAfterAction
        and not Queue.IsClearing(job) and (job.status == "queued" or job.status == "running")
        and dependenciesComplete(job, task))
end

function Queue.CanProcess(job, task, batch)
    return Queue.CanPrepareCraft(job, task) and Queue.CraftExecutionLimit(job, task) >= (batch or 1)
end

local function sharesOutput(job, itemID)
    for _, task in ipairs(job.tasks or {}) do
        if task.status ~= "complete" and task.outputItemID == itemID then return true end
    end
    return false
end

function Queue.GetBlockingCraft(preferredJob)
    if not state then return end
    local uncertain
    for _, job in ipairs(state.jobs) do
        if isOpen(job) then
            for _, task in ipairs(job.tasks or {}) do
                if task.status == "in_flight" then return task end
                if not uncertain and task.status == "uncertain"
                    and (not preferredJob or job == preferredJob or sharesOutput(preferredJob, task.outputItemID)) then
                    uncertain = task
                end
            end
        end
    end
    return uncertain
end

function Queue.NextTask(currentProfessionID, preferredJob, eligible)
    if not state then return nil end
    for _, job in ipairs(state.jobs) do
        if (not preferredJob or job == preferredJob) and isOpen(job) then
            for _, task in ipairs(job.tasks or {}) do
                if task.status == "uncertain" or task.status == "in_flight" then return job, task end
            end
        end
    end
    local fallbackJob, fallbackTask
    for _, job in ipairs(state.jobs) do
        if (not preferredJob or job == preferredJob) and (job.status == "queued" or job.status == "running") then
            for _, task in ipairs(job.tasks) do
                if Queue.CanProcess(job, task) and (not eligible or eligible(job, task)) then
                    if currentProfessionID and tostring(task.professionId) == tostring(currentProfessionID) then
                        return job, task
                    end
                    if not fallbackTask then fallbackJob, fallbackTask = job, task end
                end
            end
        end
    end
    return fallbackJob, fallbackTask
end

local function ownsCraft(job, task)
    if not job or not task or job.characterKey ~= FC.state.characterKey or job.build ~= tostring(FC.state.build)
        or Queue.GetJob(job.id) ~= job then return false end
    for _, candidate in ipairs(job.tasks or {}) do
        if candidate == task then return true end
    end
    return false
end

local blockedCraftReason38 = "The client blocked the crafting action. Review the queue before retrying."
local blockedCraftMetadata38 = {
    addonVersion = true, clientBuild = true, beforeOutput = true, batch = true, maxYield = true,
    recipeId = true, professionId = true, inventoryRevision = true, sessionGeneration = true,
    sourceCounter = true, startedAt = true, sawCraftEvent = true,
}
local blockedCraftCounts38 = {matchedExecutions = true, reportedOutput = true,
    confirmedByExactCasts = true, exactPlayerCastCount = true}

local function wholeCount(value)
    return type(value) == "number" and value >= 0 and value < math.huge and value % 1 == 0
end

function Queue.GetRetryableBlockedCraft(job)
    if FC.target ~= "forever" or tonumber(FC.state.clientBuild) ~= 71037 or tostring(FC.state.build) ~= "16001"
        or type(job) ~= "table" or job.status ~= "uncertain" or job.acquisition or Queue.IsClearing(job)
        or job.invalidatedAfterAction or job.invalidatedActiveTask then return end
    local task
    for _, candidate in ipairs(job.tasks or {}) do
        if candidate.status == "uncertain" then
            if task then return end
            task = candidate
        elseif candidate.status == "in_flight" then
            return
        end
    end
    if not task or not ownsCraft(job, task) or not dependenciesComplete(job, task)
        or task.actorKey and task.actorKey ~= job.characterKey or task.outputKind ~= "item"
        or task.blocker ~= blockedCraftReason38 or task.retriedAttempt
        or not wholeCount(task.executions) or task.executions < 1 or type(task.inputs) ~= "table" then return end
    local evidence = task.evidence
    if type(evidence) ~= "table" or evidence.addonVersion ~= "0.2.38-dev" or tonumber(evidence.clientBuild) ~= 71037
        or evidence.sawCraftEvent ~= false or evidence.recipeId ~= task.recipeId or evidence.professionId ~= task.professionId
        or not wholeCount(evidence.beforeOutput) or not wholeCount(evidence.batch) or evidence.batch < 1
        or not wholeCount(task.remainingExecutions) or task.remainingExecutions < evidence.batch
        or task.remainingExecutions > task.executions
        or type(evidence.inventoryRevision) ~= "string" or evidence.inventoryRevision == ""
        or evidence.maxYield ~= (task.yieldMax or task.yield) then return end
    for key, value in pairs(evidence) do
        if not blockedCraftMetadata38[key] and (not blockedCraftCounts38[key] or value ~= 0) then return end
    end
    return task
end

function Queue.RetryBlockedCraft(job, task, evidence)
    if not task or Queue.GetRetryableBlockedCraft(job) ~= task or task.evidence ~= evidence then return false end
    task.retriedAttempt = {evidence = task.evidence, blocker = task.blocker}
    task.status, task.evidence, task.blocker = "pending", nil, nil
    job.status = "queued"
    changed()
    return true
end

function Queue.Begin(job, task, evidence)
    if not Queue.CanProcess(job, task, evidence and evidence.batch) then return false end
    if not ownsCraft(job, task) then return false end
    task.status = "in_flight"
    task.evidence = copy(evidence or {})
    task.evidence.startedAt = type(time) == "function" and time() or 0
    task.evidence.addonVersion, task.evidence.clientBuild = FC.version, FC.state.clientBuild
    task.evidence.sawCraftEvent = false
    task.blocker = nil
    job.status = "running"
    changed()
    return true
end

-- The native adapter can prove that its last guard returned before calling Create.
function Queue.AbortBeforeSubmission(job, task, evidence, reason)
    if not job or Queue.GetJob(job.id) ~= job or job.status ~= "running"
        or not task or taskMap(job)[task.taskId] ~= task or task.status ~= "in_flight"
        or not evidence or task.evidence ~= evidence or evidence.sawCraftEvent then return false end
    task.status, task.evidence, task.blocker = "pending", nil, reason
    job.status = "queued"
    settleAfterCraft(job, task)
    changed()
    return true
end

-- Execution has already matched the interruption and verified carried stock.
function Queue.ResumeInterrupted(job, task, evidence, reason)
    if not ownsCraft(job, task) or job.status ~= "running" or task.status ~= "in_flight"
        or Queue.IsClearing(job) or job.acquisition or job.invalidatedAfterAction or job.invalidatedActiveTask
        or type(evidence) ~= "table" or task.evidence ~= evidence or evidence.sawCraftEvent ~= false
        or evidence.recipeId ~= task.recipeId or evidence.professionId ~= task.professionId
        or evidence.addonVersion ~= FC.version or not FC.state.clientBuild
        or tostring(evidence.clientBuild) ~= tostring(FC.state.clientBuild)
        or not wholeCount(evidence.batch) or evidence.batch < 1 or not wholeCount(evidence.beforeOutput)
        or not wholeCount(task.remainingExecutions) or task.remainingExecutions < evidence.batch
        or (evidence.matchedExecutions or 0) ~= 0 or (evidence.reportedOutput or 0) ~= 0
        or evidence.carriedResult or evidence.afterOutput ~= nil or (evidence.exactPlayerCastCount or 0) ~= 0
        or evidence.confirmedByExactCasts or evidence.confirmedByNativeStock then return false end
    task.interruptedAttempts = task.interruptedAttempts or {}
    task.interruptedAttempts[#task.interruptedAttempts + 1] = {evidence = copy(evidence), reason = reason}
    task.status, task.evidence, task.blocker = "pending", nil, nil
    job.status = "queued"
    changed()
    return true
end

function Queue.DiscardUnsubmittedDirectCraft(job)
    if not state or not job.goal or not job.goal.directCraft or job.status ~= "queued"
        or not job.tasks or #job.tasks ~= 1 then return end
    local task = job.tasks[1]
    if task.status ~= "pending" or task.evidence or task.completedExecutions ~= 0 then return end
    for index, candidate in ipairs(state.jobs) do
        if candidate == job then
            table.remove(state.jobs, index)
            changed()
            return
        end
    end
end

function Queue.CraftEvent(job, task, count, outputQuantity)
    if ownsCraft(job, task) and task.status == "in_flight" and task.evidence then
        local evidence = task.evidence
        evidence.sawCraftEvent = true
        if type(count) == "number" and count > 0 then
            evidence.matchedExecutions = math.min(evidence.batch, (evidence.matchedExecutions or 0) + count)
        end
        if type(outputQuantity) == "number" and outputQuantity > 0 then
            evidence.reportedOutput = (evidence.reportedOutput or 0) + outputQuantity
        end
        changed()
    end
end

function Queue.SaveCraftStock(job, task, source, inputs)
    if not ownsCraft(job, task) or task.status ~= "in_flight" or not task.evidence
        or type(source) ~= "string" or source == "none" or source == "" or type(inputs) ~= "table"
        or not next(inputs) then return end
    local evidence = task.evidence
    if not wholeCount(evidence.beforeOutput) or evidence.maxYield ~= task.yield then return end
    local expected = {}
    for _, input in ipairs(task.inputs or {}) do
        local itemID = tonumber(input.itemID)
        local perCraft = (tonumber(input.quantity) or 0) / task.executions
        if not wholeCount(itemID) or itemID < 1 or itemID == task.outputItemID
            or not wholeCount(perCraft) or perCraft < 1 then return end
        expected[itemID] = (expected[itemID] or 0) + perCraft
    end
    for itemID, input in pairs(inputs) do
        if type(input) ~= "table" or not wholeCount(input.perCraft) or input.perCraft < 1
            or expected[itemID] ~= input.perCraft or not wholeCount(input.before)
            or input.before < input.perCraft * evidence.batch then return end
        expected[itemID] = nil
    end
    if next(expected) then return end
    evidence.carriedStock = {source = source, inputs = copy(inputs), itemID = task.outputItemID,
        characterKey = job.characterKey, build = job.build, taskId = task.taskId, planRevision = job.planRevision}
end

local function consume(job, task, completed)
    for _, input in ipairs(task.inputs or {}) do
        local key = tostring(input.itemID)
        local count = input.quantity * completed / task.executions
        local manufactured = math.min(count, job.producedReservations[key] or 0)
        addCount(job.producedReservations, key, -manufactured)
        count = count - manufactured
        local allocated = math.min(count, job.reservations[key] or 0)
        addCount(job.reservations, key, -allocated)
        count = count - allocated
        if not task.allocations then
            -- Older saved jobs captured only the item's sourcing total.
            for _, requirement in ipairs(job.requirements or {}) do
                if count <= 0 then break end
                if tostring(requirement.itemID) == key then
                    local remaining = requirement.remaining or requirement.quantity
                    local used = math.min(remaining, count)
                    requirement.remaining = remaining - used
                    count = count - used
                end
            end
        end
    end
end

local function finish(job, task, completed, outputCount)
    consume(job, task, completed)
    task.completedExecutions = (task.completedExecutions or 0) + completed
    task.remainingExecutions = task.executions - task.completedExecutions
    task.evidence.afterOutput = outputCount
    task.blocker = nil
    task.status = task.remainingExecutions == 0 and "complete" or "pending"
    local destination = job.goal and job.goal.destination
    local delivery = job.goal and job.goal.intent == "delivery" and destination
        and (destination.actorKey ~= job.characterKey or destination.locationKey ~= "bags")
    local allocated, forGoal = 0, 0
    if job.allocations then
        for _, allocation in ipairs(job.allocations) do
            if allocation.producerTaskId == task.taskId then
                if allocation.goal then forGoal = forGoal + allocation.quantity
                else allocated = allocated + allocation.quantity end
            end
        end
        local promised = allocated + (delivery and forGoal or 0)
        local previous = (task.completedExecutions - completed) * task.yield
        local added = math.max(0, math.min(promised, task.completedExecutions * task.yield) - previous)
        if added > 0 then addCount(job.producedReservations, task.outputItemID, added) end
    else
        if task.taskId ~= "t1" then
            addCount(job.producedReservations, task.outputItemID, completed * task.yield)
        end
    end
    job.status = "queued"
    settleAfterCraft(job, task)
    changed()
    return true
end

local function confirmedCrafts(task, outputCount)
    local evidence = task.evidence
    if not evidence or not evidence.sawCraftEvent or evidence.recipeId and evidence.recipeId ~= task.recipeId then return end
    local before, batch, perCraft = evidence.beforeOutput, evidence.batch, task.yield
    if type(before) ~= "number" or type(outputCount) ~= "number" or type(batch) ~= "number"
        or type(perCraft) ~= "number" or perCraft < 1 then return end
    local completed, made = evidence.matchedExecutions or batch, outputCount - before
    if type(completed) ~= "number" or completed < 1 or completed > batch or completed % 1 ~= 0 then return end
    local guaranteed = completed * perCraft
    local reported = evidence.reportedOutput
    if reported then
        if made ~= reported or made < guaranteed or made > completed * (evidence.maxYield or perCraft) then return end
    elseif made ~= guaranteed then return end
    return completed
end

local function observedResult(job, task)
    local evidence = task.evidence
    local carried = evidence and evidence.carriedResult
    if type(carried) ~= "table" or carried.characterKey ~= job.characterKey or carried.build ~= job.build
        or carried.executions ~= evidence.matchedExecutions then return end
    if confirmedCrafts(task, carried.outputCount) ~= carried.executions then return end
    return carried.executions, carried.outputCount
end

function Queue.RecordCraftProgress(job, task, executions, stockProved)
    if not ownsCraft(job, task) or job.status ~= "running" or task.status ~= "in_flight" then return end
    local evidence = task.evidence
    local observed = false
    if stockProved and evidence and evidence.carriedStock and wholeCount(executions)
        and executions > (evidence.carriedStock.executions or 0) and executions <= evidence.batch then
        evidence.carriedStock.executions = executions
        observed = true
    end
    if evidence and executions > (evidence.carriedProgress or 0) and executions < evidence.batch then
        -- The cast still owns its allocations until the full batch or a terminal partial result settles.
        evidence.carriedProgress = executions
        observed = true
    end
    if observed then changed() end
end

function Queue.VisibleCompletedExecutions(task)
    local completed = task.completedExecutions or 0
    local evidence = task.evidence
    if evidence and (task.status == "in_flight" or task.status == "uncertain") then
        local carried = evidence.carriedResult
        local reported = task.status == "in_flight" and evidence.reportedOutput and evidence.matchedExecutions
        completed = completed + math.max(evidence.carriedProgress or 0, carried and carried.executions or 0, reported or 0)
    end
    return math.min(task.executions, completed)
end

function Queue.Reconcile(job, task, currentOutputCount)
    if not ownsCraft(job, task) then return false end
    if task.status == "uncertain" and job.status == "uncertain" then
        local completed, outputCount = observedResult(job, task)
        return not not (completed and completed == task.evidence.batch and finish(job, task, completed, outputCount))
    end
    if task.status ~= "in_flight" or job.status ~= "running" then return false end
    local completed = confirmedCrafts(task, currentOutputCount)
    if not completed then return false end
    local evidence = task.evidence
    if completed == evidence.batch then return finish(job, task, completed, currentOutputCount) end

    -- A partial result can settle only when the native batch ends. Retain the
    -- carried observation while this cast still owns the matched result.
    local carried = evidence.carriedResult
    if type(carried) ~= "table" or carried.executions ~= completed or carried.outputCount ~= currentOutputCount then
        evidence.carriedResult = {executions = completed, outputCount = currentOutputCount,
            characterKey = job.characterKey, build = job.build}
        changed()
    end
    return false
end

local function isCarriedRoot(job, task)
    if not job.allocations or task.recipeId ~= job.rootRecipeId or task.outputItemID ~= job.rootItemID then return end
    local goal = job.goal
    local destination = goal and goal.destination
    if not goal or goal.intent ~= "additional" or goal.demandId or not destination
        or destination.actorKey ~= job.characterKey or destination.locationKey ~= "bags" then return end
    for _, allocation in ipairs(job.allocations) do
        if allocation.producerTaskId == task.taskId and not allocation.goal then return end
    end
    return true
end

-- A final carried order can be verified by matching item-creation messages
-- and consumed reagents even if one of its outputs has already left the bags.
function Queue.ReconcileCreatedOutput(job, task, currentOutputCount, createdOutput)
    if not ownsCraft(job, task) or job.status ~= "running" or task.status ~= "in_flight"
        or not wholeCount(currentOutputCount) or not isCarriedRoot(job, task) then return false end
    local evidence = task.evidence
    if not evidence or not wholeCount(evidence.batch) or evidence.batch < 1
        or evidence.maxYield ~= task.yield or createdOutput ~= evidence.batch * task.yield then return false end
    evidence.sawCraftEvent = true
    evidence.matchedExecutions = evidence.batch
    evidence.reportedOutput = createdOutput
    evidence.confirmedByCreatedOutput = evidence.batch
    return finish(job, task, evidence.batch, currentOutputCount)
end

function Queue.MarkUncertain(job, task, reason)
    if not task or task.status ~= "in_flight" then return end
    task.status = "uncertain"
    task.blocker = reason or "Craft outcome is uncertain; inspect inventory before retrying."
    job.status = "uncertain"
    changed()
end

-- A later absolute bag count cannot prove the output of a stopped batch.
function Queue.ReconcilePartial(job, task, stopped)
    if not ownsCraft(job, task) then return false end
    if task.status ~= "uncertain" or job.status ~= "uncertain" then
        if not stopped or task.status ~= "in_flight" or job.status ~= "running" then return false end
    end
    local completed, outputCount = observedResult(job, task)
    return not not (completed and completed < task.evidence.batch and finish(job, task, completed, outputCount))
end

local function savedCraftAttempt(job)
    if FC.target ~= "forever" or not job or job.status ~= "uncertain" or job.acquisition
        or Queue.IsClearing(job) or job.invalidatedAfterAction or job.invalidatedActiveTask then return end
    local task
    for _, candidate in ipairs(job.tasks or {}) do
        if candidate.status == "in_flight" then return end
        if candidate.status == "uncertain" then
            if task then return end
            task = candidate
        end
    end
    if not task or not ownsCraft(job, task) or not dependenciesComplete(job, task)
        or task.actorKey and task.actorKey ~= job.characterKey or task.outputKind ~= "item"
        or not wholeCount(task.yield) or task.yield < 1 or task.yieldMax and task.yieldMax ~= task.yield then return end
    local evidence = task.evidence
    if type(evidence) ~= "table" or evidence.recipeId ~= task.recipeId or evidence.professionId ~= task.professionId
        or not FC.state.clientBuild or tostring(evidence.clientBuild) ~= tostring(FC.state.clientBuild)
        or not wholeCount(evidence.beforeOutput) or evidence.maxYield ~= task.yield
        or not wholeCount(evidence.batch) or evidence.batch < 1 or not wholeCount(task.remainingExecutions)
        or task.remainingExecutions < evidence.batch or evidence.afterOutput ~= nil then return end
    local locale = FC.L or {}
    if task.blocker ~= "Craft outcome needs reconciliation after reload." and task.blocker ~= locale.execTimedOut
        and task.blocker ~= locale.execInterrupted and task.blocker ~= locale.execUnproved
        and task.blocker ~= unprovedBeforeRecovery then return end
    return task, evidence
end

local function settleRecovery(job, task, count, output, kind)
    local evidence = task.evidence
    task.recoveredAttempts = task.recoveredAttempts or {}
    task.recoveredAttempts[#task.recoveredAttempts + 1] = {kind = kind, executions = count,
        outputCount = output, blocker = task.blocker, evidence = copy(evidence)}
    return finish(job, task, count, output)
end

function Queue.ReconcileSavedCraft(job, source, countItem)
    local task, evidence = savedCraftAttempt(job)
    local stock = evidence and evidence.carriedStock
    if type(stock) ~= "table" or stock.characterKey ~= job.characterKey or stock.build ~= job.build
        or stock.taskId ~= task.taskId or stock.planRevision ~= job.planRevision
        or stock.itemID ~= task.outputItemID then return false end
    local witnessed = wholeCount(stock.executions) and stock.executions <= evidence.batch and stock.executions or 0
    if stock.source == source and type(countItem) == "function" and not evidence.stockAttributionLost then
        local output = countItem(task.outputItemID)
        local made = wholeCount(output) and (output - evidence.beforeOutput) / task.yield
        local castCount = evidence.exactPlayerCastCount
        if type(stock.inputs) == "table" and next(stock.inputs) and wholeCount(made) and made > witnessed
            and made <= evidence.batch and (castCount == made or confirmedCrafts(task, output) == made) then
            local corroborated = true
            for itemID, input in pairs(stock.inputs) do
                local carried = countItem(itemID)
                if not wholeCount(carried) or input.before - carried ~= input.perCraft * made then
                    corroborated = false
                    break
                end
            end
            if corroborated then return settleRecovery(job, task, made, output, "stock") end
        end
    end
    if witnessed > 0 then
        return settleRecovery(job, task, witnessed, evidence.beforeOutput + witnessed * task.yield, "stock")
    end
    return false
end

function Queue.GetCarriedOutputRecovery(job, outputCount)
    local task, evidence = savedCraftAttempt(job)
    if not task or not isCarriedRoot(job, task) or not wholeCount(outputCount)
        or (evidence.addonVersion ~= FC.version and evidence.addonVersion ~= "0.2.52-dev"
            and evidence.addonVersion ~= "0.2.53-dev" and evidence.addonVersion ~= "0.2.54-dev"
            and evidence.addonVersion ~= "0.2.55-dev" and evidence.addonVersion ~= "0.2.56-dev"
            and evidence.addonVersion ~= "0.2.57-dev" and evidence.addonVersion ~= "0.2.58-dev"
            and evidence.addonVersion ~= "0.2.59-dev" and evidence.addonVersion ~= "0.2.60-dev"
            and evidence.addonVersion ~= "0.2.61-dev" and evidence.addonVersion ~= "0.2.62-dev"
            and evidence.addonVersion ~= "0.2.63-dev" and evidence.addonVersion ~= "0.2.64-dev"
            and evidence.addonVersion ~= "0.2.65-dev" and evidence.addonVersion ~= "0.2.66-dev"
            and evidence.addonVersion ~= "0.2.67-dev" and evidence.addonVersion ~= "0.2.68-dev"
            and evidence.addonVersion ~= "0.2.69-dev" and evidence.addonVersion ~= "0.2.70-dev")
        or (evidence.dispatch and evidence.dispatch ~= "process") or type(evidence.inventoryRevision) ~= "string"
        or evidence.inventoryRevision == "" then return end
    for _, candidate in ipairs(job.tasks) do
        if candidate ~= task and candidate.status ~= "complete" then return end
    end
    for _, candidate in ipairs(Queue.GetJobs()) do
        if candidate ~= job and candidate.characterKey == job.characterKey and candidate.rootItemID == task.outputItemID
            and candidate.status == "uncertain" then return end
    end
    local otherReserved = Queue.Reserved()[tostring(task.outputItemID)] or 0
    local carriedNew = math.max(0, math.min(outputCount - evidence.beforeOutput, outputCount - otherReserved))
    local outstanding = Queue.OutstandingOutput(job)
    local count = math.min(evidence.batch, math.floor(math.min(carriedNew, outstanding) / task.yield))
    if count > 0 then return task, count end
end

function Queue.FulfillFromCarriedOutput(job, task, evidence, outputCount, executions)
    local current, count = Queue.GetCarriedOutputRecovery(job, outputCount)
    if not current or current ~= task or current.evidence ~= evidence or count ~= executions then return false end
    task.fulfilledFromCarried = (task.fulfilledFromCarried or 0) + count * task.yield
    return settleRecovery(job, task, count, outputCount, "carried")
end

function Queue.GetJob(jobID)
    for _, job in ipairs(Queue.GetJobs()) do
        if job.id == jobID then return job end
    end
end

function Queue.GetRequirements(job)
    local requirements = {}
    for _, candidate in ipairs(Queue.GetJobs()) do
        if (not job or candidate == job) and isOpen(candidate) and candidate.status ~= "invalidated"
            and not Queue.IsClearing(candidate) then
            for index, requirement in ipairs(candidate.requirements or {}) do
                local remaining, quantity = Queue.AcquisitionRemaining(candidate, requirement)
                if remaining > 0 then
                    requirements[#requirements + 1] = {
                        job = candidate, requirement = requirement, id = index, quantity = quantity,
                        itemID = requirement.itemID,
                        kind = requirement.kind == "manual" and "auction" or requirement.kind,
                        offerId = requirement.offerId,
                        source = requirement.source,
                    }
                end
            end
        end
    end
    return requirements
end

function Queue.CreditAcquisition(job, index, count, physical)
    local requirement = job and isOpen(job) and job.status ~= "invalidated" and job.requirements[index]
    if not requirement or count <= 0 then return 0 end
    local key = tostring(requirement.itemID)
    local unallocated = Queue.AvailableCount(key, physical, job)
        - (job.reservations[key] or 0) - (job.producedReservations[key] or 0)
    local remaining = requirement.remaining or requirement.quantity
    local available = math.max(0, math.min(count, unallocated))
    local credited = math.min(available, remaining)
    local action = Queue.GetAcquisition(job, index)
    if action and action.kind == "auction" then action = nil end
    -- A final vendor bundle can contain more units than the unmet allocation.
    -- Confirm the physical receipt independently of the units applied to the job.
    local received = action and action.kind == "vendor" and available or credited
    if received > 0 then
        requirement.remaining = remaining - credited
        if requirement.auctionAwaiting then
            requirement.auctionAwaiting = math.max(0, requirement.auctionAwaiting - credited)
        end
        -- A single observed gain may be claimed once, even if two open jobs
        -- requested this item before it arrived and neither holds the output.
        for _, otherJob in ipairs(Queue.GetJobs()) do
            if isOpen(otherJob) then
                for _, other in ipairs(otherJob.requirements or {}) do
                    if tostring(other.itemID) == key then
                        other.baseline = math.min(physical, (other.baseline or physical) + credited)
                    end
                end
            end
        end
        local destination = job.goal and job.goal.destination
        local held = 0
        if job.allocations and requirement.requirementId then
            for _, allocation in ipairs(job.allocations) do
                if allocation.requirementId == requirement.requirementId and (not allocation.goal
                    or destination and (destination.actorKey ~= job.characterKey or destination.locationKey ~= "bags")) then
                    held = held + allocation.quantity
                end
            end
        else held = requirement.quantity end
        local previouslyReceived = requirement.quantity - remaining
        local newlyHeld = math.min(credited, math.max(0, held - previouslyReceived))
        if newlyHeld > 0 then addCount(job.reservations, key, newlyHeld) end
        if action then
            action.credited = (action.credited or 0) + received
            if action.credited >= action.quantity then
                action.status, job.lastAcquisition = "confirmed", action
                Queue.RemoveAcquisition(job, action)
            end
        end
        if not settleDeferredInvalidation(job) and not job.acquisition then settle(job) end
        changed()
    end
    return received
end

function Queue.CloseAcquisition(job, action)
    action = action or Queue.GetAcquisition(job)
    if not action or action.status ~= "uncertain" or not Queue.RemoveAcquisition(job, action) then return false end
    job.lastAcquisition = action
    if not settleDeferredInvalidation(job) and not job.acquisition then settle(job) end
    changed()
    return true
end

local function outstandingOutput(job, includeInvalidated, completedExecutions)
    if not isOpen(job) or Queue.IsClearing(job)
        or (job.status == "invalidated" and not includeInvalidated) then return 0, 0 end
    local remaining = job.summary and job.summary.requested or 0
    local viaBank = 0
    local taskByID = taskMap(job)
    if job.allocations then
        local produced, acquired, craftInputs, sourcedInputs = {}, {}, {}, {}
        for _, allocation in ipairs(job.allocations) do
            if allocation.producerTaskId then
                addCount(allocation.goal and produced or craftInputs, allocation.producerTaskId, allocation.quantity)
            elseif allocation.requirementId then
                addCount(allocation.goal and acquired or sourcedInputs, allocation.requirementId, allocation.quantity)
            elseif allocation.goal and allocation.kind == "owned" then
                remaining = remaining - allocation.quantity
            end
        end
        for taskID, promised in pairs(produced) do
            local task = taskByID[taskID]
            local available = task and math.max(0, completedExecutions(task) * task.yield
                - (craftInputs[taskID] or 0)) or 0
            remaining = remaining - math.min(promised, available)
        end
        local action = job.acquisition
        for index, requirement in ipairs(job.requirements or {}) do
            local id = tostring(requirement.requirementId)
            local received = requirement.quantity - (requirement.remaining or requirement.quantity)
            local inputs = sourcedInputs[id] or 0
            local available = math.max(0, received - inputs)
            local expected = acquired[id] or 0
            local confirmed = math.min(expected, available)
            remaining = remaining - confirmed
            if requirement.kind == "bank" then
                viaBank = viaBank + expected - confirmed
            elseif action and action.kind == "bank" and action.index == index then
                -- An alternate bank withdrawal covers craft inputs before the final target.
                local unconfirmed = (action.quantity or 0) - (action.credited or 0)
                local inputShortfall = math.max(0, inputs - received)
                viaBank = viaBank + math.min(expected - confirmed, math.max(0, unconfirmed - inputShortfall))
            end
        end
    elseif taskByID.t1 then
        remaining = remaining - completedExecutions(taskByID.t1) * taskByID.t1.yield
    end
    remaining = math.max(0, remaining)
    return remaining, math.min(remaining, viaBank)
end

local function settledExecutions(task)
    return task.completedExecutions or 0
end

function Queue.OutstandingOutput(job, includeInvalidated)
    return outstandingOutput(job, includeInvalidated, settledExecutions)
end

function Queue.VisibleOutstandingOutput(job)
    return outstandingOutput(job, true, Queue.VisibleCompletedExecutions)
end

function Queue.PendingCarriedSurplus(job)
    local destination = job.goal and job.goal.destination
    if not destination or destination.actorKey ~= FC.state.characterKey or destination.locationKey ~= "bags"
        or job.characterKey ~= FC.state.characterKey or job.build ~= tostring(FC.state.build)
        or (job.status ~= "queued" and job.status ~= "paused")
        or job.invalidatedAfterAction or job.invalidatedActiveTask or job.acquisition or not job.allocations
        or Queue.IsClearing(job) then
        return 0
    end
    local allocated = {}
    for _, allocation in ipairs(job.allocations) do
        if allocation.producerTaskId then addCount(allocated, allocation.producerTaskId, allocation.quantity) end
    end
    local surplus = 0
    for _, task in ipairs(job.tasks) do
        if task.status == "pending" and task.outputItemID == job.rootItemID then
            local completed = task.completedExecutions or 0
            local future = (task.executions - completed) * task.yield
            local stillAllocated = math.max(0, (allocated[task.taskId] or 0) - completed * task.yield)
            surplus = surplus + math.max(0, future - stillAllocated)
        end
    end
    return surplus
end

function Queue.Coverage(demand)
    local coverage = {}
    for _, job in ipairs(Queue.GetJobs()) do
        local eligible = job.rootItemID == demand.itemID or demand.tierKind and demand.eligible
            and demand.eligible(demand.tierKind, job.rootItemID)
        if eligible and job.goal and job.goal.demandId == demand.id
            and (not demand.actorKey or job.characterKey == demand.actorKey)
            and demand.units ~= "charge" then
            local quantity, viaBank = Queue.OutstandingOutput(job)
            local id = "FluxLogistics/" .. job.id
            if quantity > viaBank then
                coverage[#coverage + 1] = {id = id, quantity = quantity - viaBank}
            end
            if viaBank > 0 then
                coverage[#coverage + 1] = {id = id .. "/bank", quantity = viaBank, kind = "bank"}
            end
        end
    end
    return coverage
end

function Queue.SetPaused(jobID, paused)
    local job = Queue.GetJob(jobID)
    if not job or Queue.IsClearing(job) or (paused and job.status ~= "queued") or (not paused and job.status ~= "paused") then
        return false
    end
    job.status = paused and "paused" or "queued"
    changed()
    return true
end

function Queue.Move(jobID, direction)
    if not state then return false end
    for index, job in ipairs(state.jobs) do
        if job.id == jobID and not Queue.IsClearing(job) and (job.status == "queued" or job.status == "paused") then
            local target = index + (direction < 0 and -1 or 1)
            while state.jobs[target] and (not isOpen(state.jobs[target]) or state.jobs[target].status == "invalidated"
                or Queue.IsClearing(state.jobs[target])) do
                target = target + (direction < 0 and -1 or 1)
            end
            local other = state.jobs[target]
            if not other or (other.status ~= "queued" and other.status ~= "paused") then return false end
            state.jobs[index], state.jobs[target] = other, job
            changed()
            return true
        end
    end
    return false
end

function Queue.SupersededRecipeReason(recipe)
    local higherID = recipe and recipe.supersededByRecipeID
    if FC.target == "forever" and recipe and recipe.learned == true and type(higherID) == "number"
        and higherID > 0 and higherID < math.huge and higherID % 1 == 0
        and higherID ~= recipe.recipeID and higherID ~= recipe.id
        and type(recipe.blockedReason) == "string" and recipe.blockedReason ~= "" then
        return recipe.blockedReason
    end
end

local function invalidationReason(recipe, job)
    if not recipe then return end
    if recipe.learned == false then return unlearned end
    if job.characterKey == FC.state.characterKey and job.build == tostring(FC.state.build)
        and (not recipe.characterKey or recipe.characterKey == job.characterKey)
        and (not recipe.build or tostring(recipe.build) == job.build) then
        return Queue.SupersededRecipeReason(recipe)
    end
end

function Queue.InvalidateRecipes(catalog)
    local dirty
    for _, job in ipairs(Queue.GetJobs()) do
        if settleDeferredInvalidation(job) then
            dirty = true
        elseif isOpen(job) and job.status ~= "invalidated" and not Queue.IsClearing(job) then
            for _, task in ipairs(job.tasks) do
                local recipe = catalog.recipesById[task.recipeId]
                local reason = invalidationReason(recipe, job)
                if reason then
                    if task.status == "pending" then
                        if job.status == "running" or job.status == "uncertain" or job.acquisition then
                            if task.blocker ~= reason then task.blocker = reason; dirty = true end
                            if not job.invalidatedAfterAction then job.invalidatedAfterAction = reason; dirty = true end
                        else
                            task.blocker = reason
                            invalidate(job, reason)
                            dirty = true
                            break
                        end
                    elseif (task.status == "in_flight" or task.status == "uncertain")
                        and (job.invalidatedActiveTask ~= task.taskId or job.invalidatedActiveReason ~= reason) then
                        job.invalidatedActiveTask, job.invalidatedActiveReason = task.taskId, reason
                        dirty = true
                    end
                end
            end
        end
    end
    if dirty then changed() end
end

function Queue.Cancel(jobID)
    local job = Queue.GetJob(jobID)
    if not job or not isOpen(job) then return false, FC.L and FC.L.queueMissingJob or "Job not found." end
    local blocker = cancellationBlocker(job)
    if blocker then return false, blocker end
    cancel(job)
    changed()
    return true
end

function Queue.CancelGroup(jobs)
    local pending = {}
    for _, job in ipairs(jobs or {}) do
        if Queue.GetJob(job.id) ~= job then
            return false, FC.L and FC.L.queueMissingJob or "Job not found."
        end
        if isOpen(job) then
            local blocker = cancellationBlocker(job)
            if blocker then return false, blocker end
            pending[#pending + 1] = job
        end
    end
    if #pending == 0 then return false, FC.L and FC.L.queueEmpty or "The queue is empty." end
    for _, job in ipairs(pending) do cancel(job) end
    changed()
    return true
end

function Queue.Clear()
    local pending = {}
    for _, job in ipairs(Queue.GetJobs()) do
        if isOpen(job) and not Queue.IsClearing(job) then
            job.clearRequested = true
            releaseAuctionReceipts(job)
            pending[#pending + 1] = job
        end
    end
    if #pending == 0 then return false, FC.L and FC.L.queueEmpty or "The queue is empty." end
    for _, job in ipairs(pending) do settleQuietClear(job) end
    changed()
    return true
end

function Queue.Signature(plan) return signature(plan) end

if not FC.disabled and FC.On then
    FC:On("ACQUISITION_CHANGED", function(_, status, entry)
        local job = entry and entry.job
        if status == "uncertain" and Queue.IsClearing(job) then Queue.FinishDeferredInvalidation(job) end
    end)
end
