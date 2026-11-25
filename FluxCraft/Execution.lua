local _, FC = ...
if FC.disabled then return end

local Execution = {}
FC.Execution = Execution

local L = FC.L
local active, switching, switchedStep
local nativeHandoff
local nativeOnlyTasks = setmetatable({}, {__mode = "k"})
local modernResult, chooseQueuedStep, recoverFromBags, recoveryProfessionTask, scheduleRecovery
local previewBagRecovery
local generation = 0
local changing = false
local refreshPending = false
local recovering, recoveryPending
local restockIdleBlocked, restockIdleWake
local recentCastGUIDs, recentCastOrder = {}, {}
local recentCastIndex, recentCastLimit = 1, 1024

local function message(text)
    Execution.message = text
    FC:Emit("EXECUTION_CHANGED", text)
    return false, text
end

local function safe(value)
    return not (issecretvalue and issecretvalue(value))
end

local function rememberPlayerCast(castGUID)
    if recentCastGUIDs[castGUID] then return false end
    local expired = recentCastOrder[recentCastIndex]
    if expired then recentCastGUIDs[expired] = nil end
    recentCastOrder[recentCastIndex] = castGUID
    recentCastGUIDs[castGUID] = true
    recentCastIndex = recentCastIndex % recentCastLimit + 1
    return true
end

local function later(delay, callback)
    if C_Timer and type(C_Timer.After) == "function" then
        C_Timer.After(delay, callback)
    else
        callback()
    end
end

local function refresh()
    if not FC.Catalog or FC.state.ready == false then return end
    FC.Catalog.Refresh()
    FC.Queue.InvalidateRecipes(FC.Catalog.Snapshot())
    FC:Emit("PROFESSION_CHANGED")
    scheduleRecovery()
end

local function refreshSoon()
    if refreshPending then return end
    refreshPending = true
    later(0, function()
        refreshPending = false
        refresh()
    end)
end

local function currentProfession()
    if changing then return nil end
    return FC.Clients.CurrentProfessionID()
end

local function nativeCraftIdle(allowUnavailable)
    local recasts = C_TradeSkillUI and C_TradeSkillUI.GetRemainingRecasts
    if type(recasts) == "function" then
        local ok, remaining = pcall(recasts)
        if not ok or not safe(remaining) or remaining ~= 0 and not (allowUnavailable and remaining == nil) then
            return false
        end
    elseif not allowUnavailable then return false end
    local casting = UnitCastingInfo and UnitCastingInfo("player")
    local channel = UnitChannelInfo and UnitChannelInfo("player")
    return safe(casting) and casting == nil and safe(channel) and channel == nil
end

local function restockNativeIdle(allowUnavailable)
    if nativeCraftIdle(allowUnavailable) then return true end
    restockIdleBlocked = true
    return false
end

local function wakeRestockWhenIdle()
    if restockIdleWake then return end
    restockIdleWake = true
    -- Native recasts and the player cast can still be visible in the stop handler.
    later(0, function()
        restockIdleWake = nil
        if not restockIdleBlocked or active or not nativeCraftIdle(true) then return end
        restockIdleBlocked = nil
        FC:Emit("EXECUTION_CHANGED", Execution.message)
    end)
end

local function activeSession()
    local request = active
    if not request or request.generation ~= generation then return nil end
    local profession, sourceCounter = currentProfession()
    if tonumber(profession) ~= tonumber(request.task.professionId)
        or request.sourceCounter ~= sourceCounter then return nil end
    return request
end

local function activeCount(itemID)
    return FC.InventoryAdapter.Count(itemID)
end

local function requiresWholeJob(job, task, forRestock)
    if not job then return false end
    if #(job.tasks or {}) > 1 then return not FC.Queue.IsFinalCraftReady(job, task) end
    return forRestock
end

local function jobInputsCarried(job)
    return FC.InventoryAdapter.GetStatus().reliable and FC.Queue.AreJobInputsCarried(job, activeCount)
end

local function maxExecutionsFromInputs(job, task)
    local allowed = FC.Queue.CraftExecutionLimit(job, task)
    local inputs = {}
    for _, input in ipairs(task.inputs or {}) do
        local itemID = tonumber(input.itemID)
        local perExecution = input.quantity / task.executions
        if not itemID or perExecution <= 0 or perExecution ~= math.floor(perExecution) then
            return nil, L.execInvalidQty
        end
        inputs[itemID] = (inputs[itemID] or 0) + perExecution
    end
    for itemID, perExecution in pairs(inputs) do
        local count, reason = activeCount(itemID)
        if count == nil then return nil, reason end
        allowed = math.min(allowed, math.floor(FC.Queue.AvailableCount(itemID, count, job) / perExecution))
    end
    if allowed < 1 then return nil, L.execMissingMaterials end
    return allowed
end

local function clearActive()
    local finished = active
    active = nil
    return finished
end

function Execution.IsBusy()
    return active ~= nil or switching ~= nil
end

function Execution.HasNativeCraftPending()
    return nativeHandoff ~= nil
end

function Execution.GetNativeCraftRecipe()
    local handoff = nativeHandoff
    if not handoff or handoff.generation ~= generation then return end
    local job = handoff.expectedJob
    if job and (job.status ~= "queued" or FC.Queue.GetJob(job.id) ~= job or FC.Queue.IsClearing(job)
        or job.invalidatedAfterAction or job.characterKey ~= FC.state.characterKey
        or job.build ~= tostring(FC.state.build)) then return end
    if handoff.requireWhole and not jobInputsCarried(job) then return end
    local profession, counter = currentProfession()
    local selection = handoff.recipeSelection
    if tonumber(profession) ~= tonumber(selection.professionId) or counter ~= handoff.sourceCounter then return end
    return selection
end

local function clearNativeHandoff()
    local pending = nativeHandoff
    nativeHandoff = nil
    if FC.Clients and FC.Clients.CancelNativeCraft then FC.Clients.CancelNativeCraft() end
    return pending ~= nil
end

function Execution.CancelNativeCraft()
    if clearNativeHandoff() then FC:Emit("EXECUTION_CHANGED") end
end

local function liveCast(request)
    if not UnitCastingInfo or activeSession() ~= request or request.ending
        or request.castAttributionLost or request.resultAttributionLost then return end
    local _, _, _, startMs, endMs, tradeSkill, guid, _, spellID = UnitCastingInfo("player")
    if not safe(tradeSkill) or tradeSkill ~= true or not safe(spellID) or spellID ~= request.recipeSpellID
        or not safe(guid) or type(guid) ~= "string" or guid == "" or guid == request.stoppedCastGUID
        or (request.castGUID and guid ~= request.castGUID)
        or not safe(startMs) or not safe(endMs) or type(startMs) ~= "number" or type(endMs) ~= "number"
        or startMs < 0 or not (endMs > startMs and endMs < math.huge) then return end
    return {spellID = spellID, guid = guid, startTimeMs = startMs, endTimeMs = endMs}
end

function Execution.GetActiveCast(job, task)
    local request = active
    if not request or request.job ~= job or request.task ~= task then return end
    local cast = liveCast(request)
    local waiting = not cast and (request.ending or request.castSuccesses >= request.batch or request.matched >= request.batch)
    return cast, not not waiting
end

local function sampleNativeRecasts(request)
    local receipt = request.nativeReceipt
    if not receipt or request.resultAttributionLost or activeSession() ~= request then return end
    local recasts, transaction = FC.Clients.ReadNativeCraftRecasts(request.recipeSpellID)
    if recasts == nil or transaction ~= receipt.transaction or recasts > request.batch
        or receipt.recasts and recasts > receipt.recasts then
        request.nativeReceipt = nil
        return
    end
    if recasts > 0 or receipt.recasts then receipt.recasts = recasts end
    return recasts
end

local function consumedExecutions(request, receipt)
    local status = FC.InventoryAdapter.GetStatus()
    if not status.reliable or status.source ~= receipt.source or status.sourceGeneration ~= receipt.sourceGeneration then return end
    local used
    for itemID, input in pairs(receipt.inputs) do
        local carried = activeCount(itemID)
        if not safe(carried) or type(carried) ~= "number" then return end
        local executions = (input.before - carried) / input.perCraft
        if executions < 0 or executions > request.batch or executions % 1 ~= 0
            or used and used ~= executions then return end
        used = executions
    end
    return used
end

local function carriedExecutions(request, output, receipt, allowZero)
    local made = consumedExecutions(request, receipt)
    if made and (allowZero or made > 0) and output - request.evidence.beforeOutput == made * request.task.yield then
        return made
    end
end

local function confirmStockResult(request, made, method)
    request.evidence[method] = made
    if made <= request.matched then return end
    local remaining = made - request.matched
    request.matched = made
    FC.Queue.CraftEvent(request.job, request.task, remaining, remaining * request.task.yield)
end

local function recordNativeCarried(request, count, allowPartial)
    local recasts = sampleNativeRecasts(request)
    local receipt = request.nativeReceipt
    if recasts == nil or count == nil or not receipt or not receipt.recasts or not next(receipt.inputs)
        or request.maxYield ~= request.task.yield then return end
    local made = carriedExecutions(request, count, receipt)
    if not made then return end
    FC.Queue.RecordCraftProgress(request.job, request.task, made, true)
    if recasts > 0 or made < request.matched or (made < request.batch and not allowPartial) then return end
    confirmStockResult(request, made, "confirmedByNativeStock")
end

local function recordDirectCarried(request, count, allowPartial)
    local receipt = request.directReceipt
    if not request.directSubmitted or not receipt or request.castAttributionLost
        or request.maxYield ~= request.task.yield or activeSession() ~= request then return end
    local made = carriedExecutions(request, count, receipt)
    if not made or made < request.matched then return end
    if made == request.batch or allowPartial and nativeCraftIdle() then
        confirmStockResult(request, made, "confirmedByDirectStock")
    elseif made > (request.evidence.carriedProgress or 0) then
        FC.Queue.RecordCraftProgress(request.job, request.task, made, true)
    end
end

local function recordUnlinkedClassic(request, count)
    local receipt = request.classicReceipt
    if not receipt or activeSession() ~= request then return end
    local made = consumedExecutions(request, receipt)
    local quantity = count - request.evidence.beforeOutput
    if not next(receipt.inputs) then
        local status = FC.InventoryAdapter.GetStatus()
        if not status.reliable or status.source ~= receipt.source or status.sourceGeneration ~= receipt.sourceGeneration then return end
        made = request.castSuccesses
    end
    if not made or made <= request.matched or quantity < made * request.task.yield
        or quantity > made * request.maxYield then return end
    -- A stock change needs an independently matched player cast or self-create receipt.
    if made ~= request.castSuccesses and (request.createdOutputInvalid or request.createdOutput ~= quantity) then return end
    local additional = made - request.matched
    request.matched = made
    FC.Queue.CraftEvent(request.job, request.task, additional, quantity - (request.evidence.reportedOutput or 0))
end

local function reconcileCreatedOutput(request, count)
    local receipt = request.directSubmitted and request.directReceipt or request.nativeReceipt
    if not receipt or request.castAttributionLost or request.maxYield ~= request.task.yield
        or request.createdOutput ~= request.batch * request.task.yield or request.createdOutputInvalid
        or activeSession() ~= request or consumedExecutions(request, receipt) ~= request.batch then return false end
    return FC.Queue.ReconcileCreatedOutput(request.job, request.task, count, request.createdOutput)
end

local function recordCreatedProgress(request, count)
    local receipt = request.directSubmitted and request.directReceipt or request.nativeReceipt
    if not receipt or request.castAttributionLost or request.maxYield ~= request.task.yield
        or not request.createdOutput or request.createdOutputInvalid or activeSession() ~= request then return end
    local made = carriedExecutions(request, count, receipt)
    if made and made < request.batch and request.createdOutput == made * request.task.yield then
        confirmStockResult(request, made, "confirmedByCreatedStock")
    end
end

function Execution.ReconcileActive(allowPartial)
    local request = active
    if not request or request.resultAttributionLost then return false end
    local count = activeCount(request.task.outputItemID)
    if not safe(count) or type(count) ~= "number" then count = nil end
    recordNativeCarried(request, count, allowPartial)
    if count == nil then return false end
    recordUnlinkedClassic(request, count)
    -- A complete stream of exact player casts and their carried output can
    -- settle a deterministic batch even when the profession events are missing.
    local casts = request.castSuccesses
    if not request.classicReceipt and not request.castAttributionLost and casts > request.matched and request.maxYield == request.task.yield
        and count - request.evidence.beforeOutput == casts * request.task.yield and activeSession() == request then
        local full = casts == request.batch and not request.nativeInterrupted
        local receipt = request.directReceipt
        local carried = casts < request.batch and receipt and carriedExecutions(request, count, receipt) == casts
        if carried and next(receipt.inputs) then FC.Queue.RecordCraftProgress(request.job, request.task, casts, true) end
        local partial = allowPartial and carried and nativeCraftIdle()
        if full or partial then
            local remaining = casts - request.matched
            request.matched = casts
            request.evidence.confirmedByExactCasts = casts
            FC.Queue.CraftEvent(request.job, request.task, remaining, remaining * request.task.yield)
        end
    end
    recordDirectCarried(request, count, allowPartial)
    recordCreatedProgress(request, count)
    if not FC.Queue.Reconcile(request.job, request.task, count) and not reconcileCreatedOutput(request, count) then return false end
    clearActive()
    local continue = request.handoff and request.expectedJob == request.job and request.job.status == "queued"
        and not request.nativeInterrupted and request.generation == generation
    message(L.execReconciled)
    if continue then FC:Emit("NATIVE_CRAFT_SETTLED", request.job, request.recipeSelection) end
    return true
end

local function resumeInterruptedCraft(request)
    local receipt = request.directReceipt or request.nativeReceipt or request.classicReceipt
    local evidence = request.evidence
    if not (request.kind == "forever" or request.classicReceipt) or activeSession() ~= request or not receipt or not receipt.source
        or not receipt.sourceGeneration or request.castAttributionLost or request.resultAttributionLost
        or request.matched ~= 0 or request.castSuccesses ~= 0 or evidence.sawCraftEvent or evidence.carriedProgress
        or not (request.interruptedCastGUID or request.nativeStopped and request.begins > 0)
        or not nativeCraftIdle(request.kind == "classic") then return false end
    local output = activeCount(request.task.outputItemID)
    if not safe(output) or output ~= evidence.beforeOutput
        or carriedExecutions(request, output, receipt, true) ~= 0 then return false end
    evidence.interruptedCastGUID = request.interruptedCastGUID
    return FC.Queue.ResumeInterrupted(request.job, request.task, evidence, L.execInterruptedReady)
end

local function finishInterrupted(request)
    if not resumeInterruptedCraft(request) then return false end
    local guid = request.interruptedCastGUID or request.castGUID
    if guid then rememberPlayerCast(guid) end
    clearActive()
    message(L.execInterruptedReady)
    return true
end

local function stopActive(request, reason, allowPartial)
    if not request or active ~= request then return end
    if allowPartial and Execution.ReconcileActive(true) then return end
    if allowPartial and FC.Queue.ReconcilePartial(request.job, request.task, true) then
        clearActive()
        message(L.execPartial)
        return
    end
    if allowPartial and reason == L.execInterrupted and finishInterrupted(request) then return end
    local finished = clearActive()
    FC.Queue.MarkUncertain(finished.job, finished.task, reason)
    if (allowPartial or FC.Queue.IsClearing(finished.job)) and FC.Queue.ReconcilePartial(finished.job, finished.task) then
        message(L.execPartial)
        return
    end
    if FC.Queue.IsClearing(finished.job) then FC.Queue.FinishDeferredInvalidation(finished.job) end
    message(reason)
end

local function settleObservedStop(request)
    if active ~= request or not (request.nativeStopped or request.nativeInterrupted)
        or not nativeCraftIdle(request.kind == "classic") then return end
    local carried = request.evidence.carriedResult
    local output = carried and activeCount(request.task.outputItemID)
    if carried and carried.executions == request.matched and carried.executions >= request.castSuccesses
        and (request.createdOutput or 0) <= carried.executions * request.task.yield
        and (request.nativeInterrupted or request.begins <= carried.executions)
        and safe(output) and carried.outputCount == output then
        stopActive(request, L.execInterrupted, true)
        return true
    end
    if not carried and request.interruptedCastGUID and request.begins <= 1 then return finishInterrupted(request) end
end

local function reconcileObserved(request)
    if not request or active ~= request then return false end
    if Execution.ReconcileActive(request.ending) then return true end
    if request.ending then return settleObservedStop(request) end
    return false
end

local function observeTerminal(request)
    if request.ending then return reconcileObserved(request) end
    request.ending = true
    if reconcileObserved(request) then return end
    message(L.execAwaitingCastResult)
    -- Terminal events can precede the final result or the native idle state.
    later(0, function() reconcileObserved(request) end)
end

local function observeTradeStop(request, recheck)
    if not request or request.kind ~= "forever" or activeSession() ~= request or request.nativeStopped then return end
    local recasts = sampleNativeRecasts(request)
    local observed = request.nativeReceipt and request.nativeReceipt.recasts
    local sawCast = request.castGUID or request.castSuccesses > 0 or request.createdOutput or request.evidence.carriedProgress
    if (recasts and recasts > 0) or (request.begins == 0 and not observed and not sawCast) then return end
    if not nativeCraftIdle() then
        if not recheck then
            local guid = request.castGUID
            later(0, function()
                if request.castGUID == guid then observeTradeStop(request, true) end
            end)
        end
        return
    end
    request.nativeStopped = true
    observeTerminal(request)
end

local function finishSwitch(professionID, sourceCounter)
    if not switching or professionID ~= switching.profession then return false end
    local request = switching
    switching = nil
    request.sourceCounter, request.generation = sourceCounter, generation
    switchedStep = request
    message(L.execSwitched)
    FC:Emit("PROFESSION_SWITCH_READY", request.job, request.task)
    scheduleRecovery()
    return true
end

local function checkSwitch()
    if not switching then return false end
    return finishSwitch(currentProfession())
end

local function requestSwitch(job, task, openingOnly)
    if switching then return message(L.execSwitchPending) end
    if changing then return message(L.execSwitchPending) end
    if FC.target == "forever" and not nativeCraftIdle(true) then return message(L.execBusy) end
    local request = {profession = tonumber(task.professionId), job = job, task = task}
    switchedStep = nil
    switching = request
    local ok, reason = FC.Clients.SwitchProfession(request.profession)
    if not ok then
        switching = nil
        return message(reason)
    end
    if switching ~= request or checkSwitch() then
        return openingOnly == true, Execution.message, job, "profession_switch", task
    end
    if C_Timer and C_Timer.After then
        C_Timer.After(8, function()
            if switching == request and not checkSwitch() then
                switching = nil
                message(L.execSwitchTimedOut)
            end
        end)
    end
    local _, feedback = message(L.execSwitch:format(task.professionName or L.execRequiredProfession))
    return openingOnly == true, feedback, job, "profession_switch", task
end

local function craftContext(preferredJob)
    local queue, clients, catalog, inventory = FC.Queue, FC.Clients, FC.Catalog, FC.InventoryAdapter
    if not (queue and clients and catalog and inventory) then return nil, L.execServicesUnavailable end
    if active then return nil, L.execBusy end
    local status = inventory.GetStatus()
    if not status.reliable then return nil, status.reason or L.execUnreliable end

    local openID, sourceCounter = currentProfession()
    local blocker = queue.GetBlockingCraft(preferredJob)
    if blocker then return nil, blocker.status == "in_flight" and L.execBusy or L.execReview end
    local nextJob, nextTask = queue.NextTask(openID, preferredJob)
    if type(InCombatLockdown) == "function" and InCombatLockdown() then return nil, L.execCombat end
    if FC.Logistics and FC.Logistics.IsWorkflowBusy() then return nil, L.workflowBusy end
    return {openID = openID, counter = sourceCounter, job = nextJob, task = nextTask}
end

local function carriedCraftBaseline(task, live, beforeOutput)
    if not live.choice then return end
    local status = FC.InventoryAdapter.GetStatus()
    if not status.reliable or activeCount(task.outputItemID) ~= beforeOutput then return end
    local inputs = {}
    for _, reagent in ipairs(live.choice) do
        local itemID, quantity = reagent.itemID, reagent.quantity
        if not safe(itemID) or type(itemID) ~= "number" or itemID <= 0 or itemID % 1 ~= 0
            or itemID == task.outputItemID or not safe(quantity) or type(quantity) ~= "number"
            or quantity < 1 or quantity % 1 ~= 0 then return end
        local input = inputs[itemID]
        if not input then
            local before = activeCount(itemID)
            if not safe(before) or type(before) ~= "number" then return end
            input = {before = before, perCraft = 0}
            inputs[itemID] = input
        end
        input.perCraft = input.perCraft + quantity
    end
    return {inputs = inputs, source = status.source, sourceGeneration = status.sourceGeneration}
end

local function nativeStockBaseline(task, live, beforeOutput)
    local read = FC.Clients.ReadNativeCraftRecasts
    if not read then return end
    local recasts, transaction = read(live.recipeID)
    if recasts ~= 0 or not transaction then return end
    local receipt = carriedCraftBaseline(task, live, beforeOutput)
    if not receipt then return end
    receipt.transaction = transaction
    return receipt
end

local function canDispatchQueuedCraft(task, live)
    local clients = FC.Clients
    return live and live.kind == "forever" and not nativeOnlyTasks[task]
        and type(clients.CanDispatchQueuedCraft) == "function"
        and type(clients.DispatchQueuedCraft) == "function"
        and clients.CanDispatchQueuedCraft(live)
end

local function abortDeniedDirectCraft(request)
    local evidence = request.evidence
    if activeSession() ~= request or request.ending or request.nativeInterrupted
        or request.castAttributionLost or request.resultAttributionLost
        or request.begins ~= 0 or request.matched ~= 0 or request.castSuccesses ~= 0
        or evidence.sawCraftEvent or evidence.inventoryRevision ~= FC.InventoryAdapter.GetRevision()
        or evidence.beforeOutput ~= activeCount(request.task.outputItemID) then return false end
    local reason = L.execDirectRetryNative or L.execBlockedByClient
    if not FC.Queue.AbortBeforeSubmission(request.job, request.task, evidence, reason) then return false end
    nativeOnlyTasks[request.task] = true
    clearActive()
    message(reason)
    return true
end

local function submit(task, recipe, live, batch, sourceCounter, accept, queuedJob, fromClick, requireWhole)
    local dispatch = fromClick and canDispatchQueuedCraft(task, live)
    if dispatch and not nativeCraftIdle() then return message(L.execBusy) end
    local unlinkedClassic = live.kind == "classic" and not recipe.legacySpellID
    if unlinkedClassic and not nativeCraftIdle(true) then return message(L.execBusy) end
    local availableOutput, outputReason = activeCount(task.outputItemID)
    if availableOutput == nil then return message(outputReason or L.execUnreliable) end
    clearNativeHandoff()
    local preparedInventory = FC.InventoryAdapter.GetRevision()
    local token = {kind = live.kind, generation = generation,
        recipeSpellID = live.recipeID or recipe.legacySpellID, sourceCounter = sourceCounter,
        maxYield = live.maxYield or task.yield, seen = {}, matched = 0, begins = 0,
        castSuccesses = 0, requireWhole = requireWhole}
    local acceptFailure
    local function sessionMatches()
        local professionID, counter = currentProfession()
        return generation == token.generation and counter == sourceCounter
            and tonumber(professionID) == tonumber(task.professionId)
    end
    local function begin(nativeBatch)
        if token.job or active or type(nativeBatch) ~= "number" or nativeBatch < 1 or nativeBatch > batch
            or nativeBatch % 1 ~= 0 then return false end
        if not sessionMatches() then acceptFailure = L.clients.sessionChanged; return false end
        if token.directDispatch and not nativeCraftIdle() then acceptFailure = L.execBusy; return false end
        if requireWhole and not jobInputsCarried(queuedJob) then acceptFailure = L.execMissingMaterials; return false end
        local job, acceptedTask, reason = accept(nativeBatch)
        if not job then acceptFailure = reason; return false end
        token.job, token.task = job, acceptedTask
        if not FC.Queue.Begin(job, acceptedTask, {
            batch = nativeBatch, maxYield = token.maxYield, recipeId = acceptedTask.recipeId,
            professionId = acceptedTask.professionId, sessionGeneration = generation, sourceCounter = sourceCounter,
            dispatch = token.directDispatch and "process" or nil}) then
            return false
        end
        token.batch, token.evidence = nativeBatch, acceptedTask.evidence
        -- Direct dispatch can observe changes while saving. A native handoff
        -- has already seen the physical click and must retain its earlier baseline.
        local beforeOutput, countReason = activeCount(acceptedTask.outputItemID)
        local inventoryRevision = FC.InventoryAdapter.GetRevision()
        local clearing = FC.Queue.IsClearing(job)
        if token.handoff and (beforeOutput ~= availableOutput or not sessionMatches() or clearing) then
            -- Blizzard already handled the physical click. Without a qualified
            -- pre-click count the result must be reviewed instead of replayed.
            acceptFailure = L.execUnproved
            FC.Queue.MarkUncertain(job, acceptedTask, acceptFailure)
            return false
        end
        local directBusy = token.directDispatch and not nativeCraftIdle()
        if clearing or not sessionMatches() or beforeOutput == nil or directBusy then
            acceptFailure = clearing and L.queueCleared
                or beforeOutput == nil and (countReason or L.execUnreliable)
                or directBusy and L.execBusy or L.clients.sessionChanged
            FC.Queue.AbortBeforeSubmission(job, acceptedTask, token.evidence, acceptFailure)
            return false
        end
        token.evidence.beforeOutput = beforeOutput
        token.evidence.inventoryRevision = token.handoff and preparedInventory or inventoryRevision
        if token.directDispatch then
            local receipt = carriedCraftBaseline(acceptedTask, live, beforeOutput)
            if receipt and receipt.source and receipt.sourceGeneration then token.directReceipt = receipt end
        end
        if unlinkedClassic then
            local receipt = carriedCraftBaseline(acceptedTask, live, beforeOutput)
            if not receipt or not receipt.source or not receipt.sourceGeneration or not nativeCraftIdle(true) then
                acceptFailure = L.execUnreliable
                FC.Queue.AbortBeforeSubmission(job, acceptedTask, token.evidence, acceptFailure)
                return false
            end
            token.classicReceipt, token.classicName = receipt, recipe.name
        end
        active = token
        return true
    end

    local function onNativeEntry()
        if nativeHandoff ~= token or token.nativeEntry or not sessionMatches() then return end
        if not (C_Timer and C_Timer.After) then return end
        local entry = {begins = 0, results = {}, itemID = task.outputItemID, yield = task.yield,
            stock = nativeStockBaseline(task, live, availableOutput)}
        token.nativeEntry = entry
        -- Allow only observations from this native invocation, including when
        -- Blizzard stops before reaching the CreateInternal post-hook.
        C_Timer.After(0, function()
            if token.nativeEntry == entry then token.nativeEntry = nil end
        end)
    end

    local function onNativeAttempt(nativeBatch, mismatch)
        if not token.handoff then return begin(nativeBatch) end
        if nativeHandoff ~= token then return false end
        local entry = token.nativeEntry
        token.nativeEntry, nativeHandoff = nil, nil
        if not nativeBatch or not begin(nativeBatch) then
            message(acceptFailure or mismatch or L.execNativeMismatch or L.execUnavailable)
            return false
        end
        if entry then
            if not entry.mismatch and entry.begins <= nativeBatch then
                token.begins = entry.begins
                token.castGUID = entry.castGUID
                token.nativeReceipt = entry.stock
                if entry.stock then
                    FC.Queue.SaveCraftStock(token.job, token.task, entry.stock.source, entry.stock.inputs)
                end
                sampleNativeRecasts(token)
            else
                token.castAttributionLost = true
                token.resultAttributionLost = true
            end
        end
        message(L.execRequested)
        if entry and not token.resultAttributionLost then
            for _, observed in ipairs(entry.results) do
                if active ~= token then break end
                modernResult(observed.result, observed.begins)
            end
        end
        return true
    end

    local ok, started, craftReason, submission, nativeMaximum
    if dispatch then
        token.directDispatch, token.invokingDirect = true, true
        ok, started, craftReason, submission = pcall(FC.Clients.DispatchQueuedCraft, task, live, batch, begin)
        token.invokingDirect = nil
        if token.directDenied then
            if abortDeniedDirectCraft(token) then return false, Execution.message, token.job, "direct_denied" end
            ok, started, craftReason, submission = true, false, L.execBlockedByClient, "attempted"
        end
        if ok and not started and submission == "unsupported" and not token.job then
            token.directDispatch = nil
        end
    end
    if not token.directDispatch then
        ok, started, craftReason, submission, nativeMaximum =
            pcall(FC.Clients.Craft, task, live, batch, onNativeAttempt, onNativeEntry)
    end
    if not ok or not started then
        local failure = acceptFailure or (ok and craftReason) or L.execUnavailable
        if ok and submission == "not_submitted" and active == token
            and FC.Queue.AbortBeforeSubmission(token.job, token.task, token.evidence, failure) then
            clearActive()
        else
            stopActive(token, failure, false)
        end
        if token.job then FC.Queue.DiscardUnsubmittedDirectCraft(token.job) end
        local _, feedback = message(failure)
        local retained = token.job and FC.Queue.GetJob(token.job.id) == token.job and token.job
        return false, feedback, retained or nil
    end
    if submission == "native_click" then
        token.recipeSelection = {recipeID = live.recipeID, professionId = task.professionId,
            batch = nativeMaximum, itemID = task.outputItemID, yield = task.yield, name = recipe.name}
        token.expectedJob, token.expectedTask = queuedJob, task
        token.handoff, nativeHandoff = true, token
        local text = L.execNativeClick and L.execNativeClick:format(nativeMaximum, recipe.name or tostring(task.recipeId))
            or L.execUnavailable
        message(text)
        return true, text, queuedJob, "native_click"
    end
    token.directSubmitted = token.directDispatch == true
    if active == token and token.directSubmitted and token.directReceipt then
        FC.Queue.SaveCraftStock(token.job, token.task, token.directReceipt.source, token.directReceipt.inputs)
    end
    if active == token and not Execution.ReconcileActive() then
        message(L.execRequested)
    end
    return true, Execution.message or L.execReconciled, token.job, token.directDispatch and "dispatched" or nil
end

local function validateTaskRecipe(job, task)
    local snapshot = FC.Catalog.Snapshot()
    local recipe = snapshot.recipesById[task.recipeId]
    if not recipe or recipe.learned ~= true or (recipe.characterKey and recipe.characterKey ~= job.characterKey)
        or (recipe.build and tostring(recipe.build) ~= job.build) then
        return nil, L.execNotLearned
    end
    local supersededReason = FC.Queue.SupersededRecipeReason(recipe)
    if supersededReason then return nil, supersededReason, snapshot end
    if task.recipeRevision and recipe.revision and task.recipeRevision ~= recipe.revision then
        return nil, L.execRecipeChanged
    end
    if recipe.professionId ~= task.professionId or recipe.outputItemID ~= task.outputItemID
        or recipe.yield ~= task.yield then
        return nil, L.execRecipeChanged
    end
    return recipe
end

local function validateQueuedStep(job, task)
    if not job or FC.Queue.GetJob(job.id) ~= job then return nil, L.noReadyCraft end
    if job.characterKey ~= FC.state.characterKey or job.build ~= tostring(FC.state.build) then
        return nil, L.execWrongActor
    end
    if job.status == "invalidated" then return nil, job.invalidationReason or L.noReadyCraft end
    if not FC.Queue.CanProcess(job, task) then return nil, L.noReadyCraft end
    return validateTaskRecipe(job, task)
end

local function liveBatch(live, wanted)
    if not live then return wanted end
    local count = math.min(wanted, live.maxExecutions or wanted)
    if live.info and live.info.canCreateMultiple == false then count = math.min(count, 1) end
    return count
end

local function resolveQueuedStep(job, task, openID, revealLegacy)
    local recipe, blocker, supersededCatalog = validateQueuedStep(job, task)
    if not recipe then return nil, blocker, nil, supersededCatalog end
    local live
    if tonumber(task.professionId) == openID then
        live, blocker = FC.Clients.Resolve(task, recipe, revealLegacy)
        if not live then return nil, blocker, recipe end
    else
        local cooldown = recipe.constraints and recipe.constraints.cooldownUntil
        local now = cooldown and GetServerTime and GetServerTime()
        if cooldown and (not now or cooldown > now) then return nil, L.clients.cooldown, recipe end
    end
    local batch, inputReason = maxExecutionsFromInputs(job, task)
    if not batch then return nil, inputReason, recipe end
    batch = liveBatch(live, batch)
    if batch < 1 then return nil, L.execMissingMaterials, recipe end
    return {job = job, task = task, recipe = recipe, live = live, batch = batch}
end

local function carriedRootStep(job, prerequisite, openID)
    if not FC.Logistics or not job.goal or job.goal.intent ~= "additional" or job.status ~= "queued"
        or (prerequisite.completedExecutions or 0) < 1 or prerequisite.outputItemID == job.rootItemID
        or not FC.Queue.CanReplace(job) or #FC.Queue.GetRequirements(job) > 0 then return end
    local root
    for _, candidate in ipairs(job.tasks) do
        if candidate.recipeId == job.rootRecipeId and candidate.outputItemID == job.rootItemID
            and candidate.status == "pending" then
            if root then return end
            root = candidate
        end
    end
    if not root or tonumber(root.professionId) ~= openID then return end
    local dependsOnPrerequisite
    for _, dependency in ipairs(root.dependencies or {}) do
        if dependency == prerequisite.taskId then dependsOnPrerequisite = true; break end
    end
    local executions = root.remainingExecutions
    if not dependsOnPrerequisite or not executions or executions < 1
        or FC.Queue.OutstandingOutput(job) ~= executions * root.yield then return end
    local recipe = validateTaskRecipe(job, root)
    if not recipe then return end
    local live = FC.Clients.Resolve(root, recipe)
    if not live then return end

    local function preview()
        if not FC.Queue.CanReplace(job) or job.status ~= "queued" or not validateTaskRecipe(job, root) then return end
        local plan, details = FC.Logistics.Preview({recipeId = root.recipeId, directMaximum = executions,
            reagentChoice = root.reagentChoice, bagsOnly = true, autoBuyVendor = false, replaces = job})
        if plan and plan.status == "ready" and #plan.requirements == 0 and #plan.tasks == 1
            and plan.tasks[1].executions == executions then return plan, details end
    end
    local plan = preview()
    if not plan then return end
    return plan.tasks[1], recipe, live, preview
end

local function restockProfession()
    local queue, clients, catalog, inventory = FC.Queue, FC.Clients, FC.Catalog, FC.InventoryAdapter
    if not (queue and clients and catalog and inventory) then return end
    if active or switching or changing or (InCombatLockdown and InCombatLockdown()) then return end
    if Execution.GetNativeCraftRecipe() then return end
    if catalog.IsForeignSession and catalog.IsForeignSession() then return end
    local trade = FC.target == "forever" and C_TradeSkillUI
    if trade and trade.IsDataSourceChanging and trade.IsDataSourceChanging() then return end
    local profession = currentProfession()
    local openID = tonumber(profession)
    local function selection(job, task, quantity)
        return {jobId = job.id, planRevision = job.planRevision, taskId = task.taskId,
            itemID = task.outputItemID, quantity = quantity, outputQuantity = quantity * task.yield,
            professionID = tonumber(task.professionId), professionName = task.professionName or L.execRequiredProfession},
            task, job
    end
    local context, problem = craftContext()
    if context then
        local step = chooseQueuedStep(context, nil, nil, true)
        if step and not step.live and (FC.target ~= "forever" or restockNativeIdle(true)) then
            return selection(step.job, step.task, step.batch)
        end
    elseif problem == L.execReview then
        local job, blocked = queue.NextTask(openID)
        local task, root = recoveryProfessionTask(job)
        if task and task == blocked and inventory.GetStatus().reliable
            and previewBagRecovery(job, root, queue.OutstandingOutput(job)) then
            return selection(job, task, task.remainingExecutions)
        end
    end
end

function Execution.GetRestockProfession()
    local selection = restockProfession()
    return selection
end

function Execution.OpenRestockProfession(selection)
    local current, task, job = restockProfession()
    if not current or not selection or current.jobId ~= selection.jobId or current.taskId ~= selection.taskId
        or current.planRevision ~= selection.planRevision or current.itemID ~= selection.itemID
        or current.quantity ~= selection.quantity or current.outputQuantity ~= selection.outputQuantity
        or current.professionID ~= selection.professionID then return false, L.noReadyCraft end
    return requestSwitch(job, task, true)
end

function chooseQueuedStep(context, preferredJob, preferredTask, forRestock, revealLegacy)
    if switching then return nil, L.execSwitchPending end
    local openID = tonumber(context.openID)
    local job, task = preferredJob or context.job, preferredTask or context.task
    if preferredJob and not preferredTask then
        job, task = FC.Queue.NextTask(context.openID, preferredJob)
        job = job or preferredJob
    end
    local carried = {}
    local function resolve(candidateJob, candidateTask, alternate)
        if forRestock and candidateJob and (candidateJob.status ~= "queued" or candidateJob.acquisition) then
            return nil, L.workflowBusy
        end
        local step, blocker, recipe, supersededCatalog = resolveQueuedStep(candidateJob, candidateTask, openID,
            revealLegacy and not alternate)
        if step and requiresWholeJob(candidateJob, step.task, forRestock) then
            if carried[candidateJob] == nil then carried[candidateJob] = jobInputsCarried(candidateJob) end
            if not carried[candidateJob] then return nil, L.execMissingMaterials, step.recipe end
        end
        if not forRestock then
            if supersededCatalog and not alternate then
                FC.Queue.InvalidateRecipes(supersededCatalog)
            elseif blocker == L.clients.supersededRank then
                refreshSoon()
            end
        end
        return step, blocker, recipe
    end
    local function findReady(excludedTask)
        local byTask = {}
        local _, candidate = FC.Queue.NextTask(context.openID, preferredJob, function(candidateJob, candidateTask)
            if candidateTask == excludedTask then return false end
            local step = resolve(candidateJob, candidateTask, true)
            byTask[candidateTask] = step
            return step ~= nil
        end)
        return byTask[candidate]
    end
    local prior = switchedStep
    if prior and prior.generation == generation and prior.profession == openID
        and prior.sourceCounter == context.counter and not preferredTask and (not preferredJob or prior.job == preferredJob) then
        local selected = resolve(prior.job, prior.task)
        if selected then return selected end
    end
    local step, blocker, recipe = resolve(job, task)
    -- A stopped batch can leave enough physical output to supply its parent
    -- without proving another craft. Replace only the remaining local work.
    if not step and not forRestock and not preferredTask and blocker == L.execMissingMaterials and recipe then
        local root, rootRecipe, live, preview = carriedRootStep(job, task, openID)
        if root then
            return {job = job, task = root, recipe = rootRecipe, live = live, batch = root.executions,
                accept = function()
                    local plan, details = preview()
                    if not plan then return nil, nil, L.execMissingMaterials end
                    local replacement, reason = FC.Queue.Accept(plan, preview, job)
                    if not replacement then return nil, nil, reason end
                    replacement.projection = details and details.projection
                    return replacement, replacement.tasks[1]
                end}
        end
    end
    if not step and not preferredTask then step = findReady(task) end
    return step, blocker
end

local function queuedBatch(step, preferredTask)
    if step.accept or not step.live or nativeHandoff or not FC.Logistics then return end
    local owner = step.job
    local orders = FC.Queue.GetBatchOrders(owner)
    if not orders then return end
    local quantity, included, root = 0, {}
    for _, job in ipairs(orders) do
        quantity = quantity + FC.Queue.OutstandingOutput(job)
        included[job] = true
        for _, task in ipairs(job.tasks) do
            if task.status == "pending" then
                if nativeOnlyTasks[task] then return end
                if job == owner and task.recipeId == owner.rootRecipeId then root = task end
            end
        end
    end
    if not root or not validateTaskRecipe(owner, root) then return end

    local function preview()
        return FC.Logistics.Preview({
            recipeId = root.recipeId, quantity = quantity, destination = owner.goal.destination,
            choices = owner.goal.sourceChoices, reagentChoice = root.reagentChoice,
            batchOrders = included, bagsOnly = true, autoBuyVendor = false,
        })
    end
    local plan, details = preview()
    if not FC.Queue.MatchesBatchPlan(plan, orders) then return end

    -- The plan is ordered with producers first. Resolve a dependency-free
    -- task in the open profession and retain its original queue reference.
    for _, planned in ipairs(plan.tasks) do
        if #planned.dependencies == 0 and planned.professionId == step.task.professionId then
            for _, job in ipairs(orders) do
                for _, task in ipairs(job.tasks) do
                    if task.status == "pending" and FC.Queue.SameCraft(task, planned) then
                        local recipe = validateQueuedStep(job, task)
                        local live = recipe and FC.Clients.Resolve(planned, recipe)
                        local count = liveBatch(live, planned.executions)
                        if live and count > 0 then
                            if preferredTask and not FC.Queue.SameCraft(preferredTask, planned) then return end
                            return {job = job, task = task, batch = count, live = live, plan = plan,
                                plannedTaskId = planned.taskId, details = details, orders = orders, preview = preview}
                        end
                    end
                end
            end
        end
    end
end

function Execution.GetReadyRestockCraft(job, reprepareNative)
    if Execution.GetNativeCraftRecipe() then
        local request = nativeHandoff
        local exactJob, exactTask = request.expectedJob, request.expectedTask
        if not reprepareNative or request.nativeEntry or not exactJob or not exactTask
            or job and job ~= exactJob then return end
        local context = craftContext(exactJob)
        local step = context and chooseQueuedStep(context, exactJob, exactTask, true)
        if step and step.live and restockNativeIdle() then
            -- Reoffer the armed task when its native controls are unavailable.
            -- The next press can prepare the same task without submitting a craft.
            return exactTask, step.batch, exactJob, false, true
        end
        return
    end
    local context = craftContext(job)
    if not context then return end
    local step = chooseQueuedStep(context, job, nil, true)
    if not step or not step.live then return end
    step = queuedBatch(step) or step
    local direct = canDispatchQueuedCraft(step.task, step.live) == true
    if direct and not restockNativeIdle() then return end
    return step.task, step.batch, step.job, direct
end

local function processQueuedCraft(preferredJob, preferredTask, fromClick, forRestock)
    local context, problem = craftContext(preferredJob)
    if not context then return message(problem) end
    finishSwitch(tonumber(context.openID), context.counter)
    local step, blocker = chooseQueuedStep(context, preferredJob, preferredTask, forRestock, fromClick)
    if not step then return message(blocker) end
    local batch = queuedBatch(step, preferredTask)
    local combined
    if batch then
        local reason
        combined, reason = FC.Queue.AcceptBatch(batch.plan, batch.preview, batch.orders)
        if not combined then return message(reason) end
        combined.projection = batch.details and batch.details.projection
        step = nil
        for _, task in ipairs(combined.tasks) do
            if task.taskId == batch.plannedTaskId then
                step, blocker = chooseQueuedStep(context, combined, task)
                break
            end
        end
        if not step then
            local _, feedback = message(blocker or L.noReadyCraft)
            return false, feedback, combined
        end
    end
    local job, task = step.job, step.task
    if not step.live then return requestSwitch(job, task) end
    switchedStep = nil
    local ok, feedback, accepted, phase = submit(task, step.recipe, step.live, step.batch, context.counter, step.accept or function(nativeBatch)
        -- The native form counts all carried units. Recheck the queue's
        -- usable share after it has finished preparing the exact batch.
        local available, reason = maxExecutionsFromInputs(job, task)
        if not available or available < nativeBatch then
            return nil, nil, reason or L.execMissingMaterials
        end
        return job, task
    end, job, fromClick, not step.accept and requiresWholeJob(job, task, forRestock))
    return ok, feedback, accepted or combined, phase
end

function Execution.ProcessNext(preferredJob, preferredTask, forRestock)
    return processQueuedCraft(preferredJob, preferredTask, nil, forRestock)
end

function Execution.ProcessClick(preferredJob, preferredTask, forRestock)
    local request = active
    if request and request.ending and (not preferredJob or preferredJob == request.job)
        and (not preferredTask or preferredTask == request.task) then
        if not reconcileObserved(request) then return message(L.execAwaitingCastResult) end
        -- A press for a just-completed order must not run a different order.
        preferredJob = request.job
    end
    if FC.target == "forever" and FC.Queue then
        checkSwitch()
        local job, task = FC.Queue.NextTask(currentProfession(), preferredJob)
        if task and task.status == "uncertain"
            and (not preferredTask or preferredTask == task) and Execution.CanReplanFromBags(job) then
            local replacement, feedback = recoverFromBags(job)
            if not replacement then return message(feedback) end
            local ok, result, accepted, phase, exactTask = processQueuedCraft(replacement, nil, true, forRestock)
            return ok, result, accepted or replacement, phase, exactTask
        end
    end
    return processQueuedCraft(preferredJob, preferredTask, true, forRestock)
end

local function selectedCraftRecipe(recipeID, context)
    local catalog = FC.Catalog.Snapshot()
    local recipe = catalog.recipesById[recipeID]
    if not recipe or recipe.learned ~= true or recipe.characterKey ~= FC.state.characterKey
        or (recipe.build and tostring(recipe.build) ~= tostring(FC.state.build)) then
        return nil, L.execNotLearned
    end
    if not context.openID or tonumber(context.openID) ~= tonumber(recipe.professionId) then
        return nil, L.clients.waitProfession
    end
    return recipe, catalog
end

function Execution.QueueAllSelected(recipeID, choice, keepNativeRemainder)
    if active then return nil, L.execBusy end
    if switching then return nil, L.execSwitchPending end
    if not FC.Logistics or not FC.Planner then return nil, L.execServicesUnavailable end
    local inventory = FC.InventoryAdapter.GetStatus()
    if not inventory.reliable then return nil, inventory.reason or L.execUnreliable end
    local recipe, catalog = selectedCraftRecipe(recipeID, {openID = currentProfession()})
    if not recipe then return nil, catalog end
    local function preview(maximum, exactChoice)
        local snapshot = FC.Catalog.Snapshot()
        if not snapshot.recipesById[recipeID] or snapshot.recipesById[recipeID].revision ~= recipe.revision then
            return nil, L.execRecipeChanged
        end
        local direct, directDetails = FC.Logistics.Preview({recipeId = recipeID, directMaximum = maximum, reagentChoice = exactChoice,
            bagsOnly = true, autoBuyVendor = false}, snapshot)
        if not FC.Logistics.PreviewAvailableCrafts or direct and direct.summary.executions == maximum then
            return direct, directDetails
        end
        local chain, chainDetails = FC.Logistics.PreviewAvailableCrafts(recipeID, maximum, exactChoice, snapshot)
        if chain and (not direct or chain.summary.executions > direct.summary.executions) then
            for _, task in ipairs(chain.tasks) do
                if task.recipeId ~= recipeID then return chain, chainDetails end
            end
        end
        if direct then return direct, directDetails end
        return nil, type(chainDetails) == "string" and chainDetails or directDetails
    end
    local maximum, exactChoice = 999, choice
    local plan, detail = preview(maximum, exactChoice)
    if not plan then return nil, detail end
    if plan.status ~= "ready" or #plan.requirements > 0 then return nil, plan.blocker or L.execMissingMaterials end
    -- A direct order can be checked on the open profession. Its native form
    -- cannot qualify a final recipe whose prerequisite is still unmade.
    if #plan.tasks == 1 then
        local task = plan.tasks[1]
        local live, blocker = FC.Clients.Resolve(task, recipe)
        if not live then return nil, blocker or L.execUnavailable end
        local nativeMaximum = math.min(task.executions, live.maxExecutions or task.executions)
        if not keepNativeRemainder and live.info and live.info.canCreateMultiple == false then
            nativeMaximum = math.min(nativeMaximum, 1)
        end
        if nativeMaximum < 1 then return nil, L.execMissingMaterials end
        if nativeMaximum < task.executions then
            maximum, exactChoice = nativeMaximum, task.reagentChoice
            plan, detail = preview(maximum, exactChoice)
            if not plan then return nil, detail end
        end
    end
    local job, reason = FC.Queue.Accept(plan, function() return preview(maximum, exactChoice) end)
    return job, reason, detail
end

function Execution.CreateSelected(recipeID, quantity, choice, sourceChoices, fromClick)
    if not FC.Logistics then return message(L.execServicesUnavailable) end
    if type(quantity) ~= "number" or quantity < 1 or quantity % 1 ~= 0 then return message(L.quantityError) end
    local recipe, catalog = selectedCraftRecipe(recipeID, {openID = currentProfession()})
    if not recipe then return message(catalog) end
    if type(choice) ~= "table" or not choice.reagents then choice = nil end
    if not recipe.yield or recipe.yield < 1 then return message(L.yieldUnknown) end
    local executions = math.ceil(quantity / recipe.yield)

    local function preview()
        local snapshot = FC.Catalog.Snapshot()
        local current = snapshot.recipesById[recipeID]
        if not current or current.revision ~= recipe.revision then return nil, L.execRecipeChanged end
        if not sourceChoices or not next(sourceChoices) then
            local carried, details = FC.Logistics.Preview({recipeId = recipeID, directMaximum = executions,
                reagentChoice = choice, bagsOnly = true, autoBuyVendor = false}, snapshot)
            if carried and carried.summary.executions == executions then
                if carried.summary.requested == quantity then return carried, details end
                return FC.Logistics.Preview({recipeId = recipeID, quantity = quantity,
                    reagentChoice = carried.tasks[1].reagentChoice, bagsOnly = true, autoBuyVendor = false}, snapshot)
            end
            local chain, chainDetails = FC.Logistics.Preview({recipeId = recipeID, quantity = quantity,
                reagentChoice = choice, bagsOnly = true, autoBuyVendor = false}, snapshot)
            if chain and chain.status == "ready" and #chain.requirements == 0 and chain.summary.additionalCash == 0 then
                return chain, chainDetails
            end
        end
        local plan, details = FC.Logistics.Preview({recipeId = recipeID, quantity = quantity,
            reagentChoice = choice, choices = sourceChoices, deferRecipeRequirements = true}, snapshot)
        if plan and plan.goal then plan.goal.createOnQueue = true end
        return plan, details
    end

    local plan, details = preview()
    if not plan or plan.status == "blocked" then return message(plan and plan.blocker or details) end
    local job, reason = FC.Queue.Accept(plan, preview)
    if not job then return message(reason) end
    job.projection = details and details.projection
    local readyJob, task = FC.Queue.NextTask(currentProfession(), job)
    if readyJob ~= job or not task then
        local _, feedback = message(L.queueAccepted:format(job.id))
        return true, feedback, job
    end
    local process = fromClick and Execution.ProcessClick or Execution.ProcessNext
    local _, feedback, accepted, phase = process(job, task)
    return true, feedback, accepted or job, phase
end

function Execution.CraftSelected(recipeID, all, choice, maximum, fromClick)
    if all and FC.Logistics and (FC.Logistics.PreviewAvailableCrafts
        or FC.Clients and FC.Clients.UsesNativeCraftHandoff and FC.Clients.UsesNativeCraftHandoff()) then
        local job, reason, details = Execution.QueueAllSelected(recipeID, choice, true)
        if not job then return message(reason) end
        job.projection = details and details.projection
        local process = fromClick and Execution.ProcessClick or Execution.ProcessNext
        local _, feedback, accepted, phase = process(job)
        return true, feedback, accepted or job, phase
    end
    local context, problem = craftContext()
    if not context then return message(problem) end
    if not FC.Planner then return message(L.execServicesUnavailable) end
    if switching then return message(L.execSwitchPending) end
    local recipe, catalog = selectedCraftRecipe(recipeID, context)
    if not recipe then return message(catalog) end
    if type(choice) ~= "table" or not choice.reagents then choice = nil end

    local function preview(maximum, snapshot, requested)
        local counts, reason = FC.InventoryAdapter.Snapshot(FC.Planner.DirectReagentItems(recipe))
        if not counts then return nil, reason or L.execUnreliable end
        local now = GetServerTime and GetServerTime() or type(time) == "function" and time() or nil
        return FC.Planner.PreviewDirect({catalog = snapshot, rootRecipeId = recipeID,
            characterKey = FC.state.characterKey, now = now, inventory = FC.Queue.AvailableInventory(counts),
            revisions = {inventory = FC.InventoryAdapter.GetRevision() .. "/" .. FC.Queue.GetRevision()}},
            maximum, requested)
    end

    local plan, reason = preview(all and 999 or maximum or 1, catalog, choice)
    if not plan then return message(reason) end
    local task = plan.tasks[1]
    local live, blocker = FC.Clients.Resolve(task, recipe)
    if not live then return message(blocker or L.execUnavailable) end
    return submit(task, recipe, live, task.executions, context.counter, function(nativeBatch)
        local function exactPreview()
            local snapshot = FC.Catalog.Snapshot()
            local current = snapshot.recipesById[recipeID]
            if not current or current.revision ~= recipe.revision then return nil, L.execRecipeChanged end
            -- The native control can limit its first batch to fewer crafts
            -- than the selected carried plan. Keep eligible later work queued.
            local exact, why = preview(task.executions, snapshot, task.reagentChoice)
            if not exact then return nil, why end
            if exact.tasks[1].executions < nativeBatch then return nil, L.execMissingMaterials end
            return exact
        end
        local exact, why = exactPreview()
        if not exact then return nil, nil, why end
        local job, rejected = FC.Queue.Accept(exact, exactPreview)
        if not job then return nil, nil, rejected end
        return job, job.tasks[1]
    end)
end

function Execution.ProcessTask(job, task)
    return Execution.ProcessNext(job, task)
end

local function retryableBlockedCraft(job)
    if active or switching or nativeHandoff then return nil, L.execBusy end
    local task = FC.Queue.GetRetryableBlockedCraft(job)
    if not task then return nil, L.execNothingToReview end
    local recipe, reason = validateTaskRecipe(job, task)
    if not recipe then return nil, reason end
    if recipe.completeness ~= "complete" or task.recipeRevision == nil or recipe.revision ~= task.recipeRevision then
        return nil, L.execRecipeChanged
    end
    return task
end

function Execution.CanRetryBlockedCraft(job)
    return retryableBlockedCraft(job) ~= nil
end

function Execution.RetryBlockedCraft(job)
    local task, reason = retryableBlockedCraft(job)
    if not task then return message(reason) end
    if FC.Logistics and FC.Logistics.IsWorkflowBusy() then return message(L.workflowBusy) end
    local inventory = FC.InventoryAdapter
    local status = inventory.GetStatus()
    local changed = L.execBlockedRetryChanged or L.execUnproved
    if not status.reliable then return message(status.reason or changed) end

    local evidence, revision = task.evidence, inventory.GetRevision()
    local output = activeCount(task.outputItemID)
    local available = maxExecutionsFromInputs(job, task)
    if output ~= evidence.beforeOutput or not available or available < evidence.batch
        or revision ~= inventory.GetRevision() or not inventory.GetStatus().reliable then return message(changed) end
    if retryableBlockedCraft(job) ~= task or not FC.Queue.RetryBlockedCraft(job, task, evidence) then
        return message(L.execNothingToReview)
    end
    local _, feedback = message(L.execBlockedRetryReady or L.ready)
    return true, feedback
end

function recoveryProfessionTask(job)
    if active or switching or changing or nativeHandoff or (InCombatLockdown and InCombatLockdown())
        or not FC.Logistics or FC.Logistics.IsWorkflowBusy()
        or FC.Catalog.IsForeignSession and FC.Catalog.IsForeignSession()
        or not nativeCraftIdle(true) then return end
    local task, root = FC.Queue.GetNativeReplanTask(job)
    local openID = currentProfession()
    if not task or tonumber(openID) == tonumber(task.professionId) or not validateTaskRecipe(job, root) then return end
    return task, root
end

function Execution.GetRecoveryProfession(job)
    local task = recoveryProfessionTask(job)
    if task then return tonumber(task.professionId), task.professionName or L.execRequiredProfession end
end

function Execution.OpenRecoveryProfession(job)
    local task = recoveryProfessionTask(job)
    if not task then return message(L.execReplanUnavailable or L.execUnproved) end
    return requestSwitch(job, task, true)
end

local function nativeReplanTask(job)
    if active or switching or nativeHandoff or (InCombatLockdown and InCombatLockdown())
        or not FC.Logistics or FC.Logistics.IsWorkflowBusy() then return end
    local task, root = FC.Queue.GetNativeReplanTask(job)
    local openID = currentProfession()
    if not task or tonumber(openID) ~= tonumber(task.professionId) then return end
    if not nativeCraftIdle() then return end
    if not FC.InventoryAdapter.GetStatus().reliable or not validateTaskRecipe(job, root) then return end
    return task, root
end

function Execution.CanReplanFromBags(job)
    return nativeReplanTask(job) ~= nil
end

function previewBagRecovery(job, root, quantity)
    if quantity < 1 then return end
    local plan, context = FC.Logistics.Preview({
        recipeId = root.recipeId, quantity = quantity, intent = "additional",
        destination = job.goal.destination, choices = job.goal.sourceChoices, reagentChoice = root.reagentChoice,
        replaces = job, bagsOnly = true, autoBuyVendor = false,
    })
    if plan and plan.status == "ready" and #plan.requirements == 0 then return plan, context end
end

local function buildRecovery(job)
    local task, root = nativeReplanTask(job)
    local unavailable = L.execReplanUnavailable or L.execUnproved
    if not task then return nil, unavailable end
    local quantity = FC.Queue.OutstandingOutput(job)
    if quantity < 1 then return nil, unavailable end
    local function preview()
        if nativeReplanTask(job) ~= task or FC.Queue.OutstandingOutput(job) ~= quantity then return end
        return previewBagRecovery(job, root, quantity)
    end
    local plan, context = preview()
    if not plan then return nil, L.execReplanNeedsBags or L.execMissingMaterials end
    local replacement, reason = FC.Queue.AcceptNativeReplan(plan, preview, job, task)
    if not replacement then return nil, reason or unavailable end
    replacement.projection = context and context.projection
    return replacement
end

function recoverFromBags(job)
    if recovering then return nil, L.execBusy end
    recovering = true
    local ok, replacement, reason = pcall(buildRecovery, job)
    recovering = nil
    if not ok then error(replacement, 0) end
    if not replacement then return nil, reason end
    local text = L.execReplannedFromBags or L.ready
    FC:Emit("CRAFT_RECOVERY_REPLANNED", job, replacement)
    message(text)
    scheduleRecovery()
    return replacement, text
end

local function recoveryInventory()
    if active or switching or changing or nativeHandoff or (InCombatLockdown and InCombatLockdown())
        or FC.Logistics and FC.Logistics.IsWorkflowBusy()
        or FC.Catalog.IsForeignSession and FC.Catalog.IsForeignSession() or not nativeCraftIdle(true) then return end
    local inventory = FC.InventoryAdapter
    local status = inventory.GetStatus()
    if not status.reliable then return end
    local revision = inventory.GetRevision()
    local function countItem(itemID)
        local count = activeCount(itemID)
        if safe(count) and type(count) == "number" and revision == inventory.GetRevision()
            and inventory.GetStatus().reliable then return count end
    end
    return countItem, status.source
end

local function reconcileSavedCraft(job, task, countItem, source)
    if not countItem or not job or not task or task.status ~= "uncertain" then return false end
    return FC.Queue.Reconcile(job, task) or FC.Queue.ReconcilePartial(job, task)
        or FC.Queue.ReconcileSavedCraft(job, source, countItem)
end

function Execution.GetCarriedOutputRecovery(job)
    if FC.target ~= "forever" or not job or job.status ~= "uncertain" or not job.rootItemID then return end
    local countItem = recoveryInventory()
    if not countItem then return end
    local outputCount = countItem(job.rootItemID)
    local task, count = FC.Queue.GetCarriedOutputRecovery(job, outputCount)
    if not task or not validateTaskRecipe(job, task) then return end
    return {jobId = job.id, taskId = task.taskId, planRevision = job.planRevision,
        itemID = task.outputItemID, professionID = task.professionId, professionName = task.professionName,
        quantity = count * task.yield, executions = count, remainingExecutions = task.remainingExecutions - count,
        outputCount = outputCount, evidence = task.evidence}
end

function Execution.ResumeWithCarriedOutput(job, selection)
    local current = Execution.GetCarriedOutputRecovery(job)
    local reason = L.execCarriedOutputChanged or L.execUnproved
    if not current or type(selection) ~= "table" then return message(reason) end
    for key, value in pairs(current) do
        if selection[key] ~= value then return message(reason) end
    end
    local task
    for _, candidate in ipairs(job.tasks) do
        if candidate.taskId == current.taskId then task = candidate; break end
    end
    if not FC.Queue.FulfillFromCarriedOutput(job, task, current.evidence, current.outputCount, current.executions) then
        return message(reason)
    end
    local _, text = message(L.execCarriedOutputResumed or L.execReconciled)
    return true, text, task
end

function scheduleRecovery()
    if FC.target ~= "forever" or FC.state.ready == false or recovering or recoveryPending
        or not (C_Timer and type(C_Timer.After) == "function") then return end
    recoveryPending = true
    C_Timer.After(0, function()
        recoveryPending = nil
        if FC.state.ready == false or recovering or not FC.Queue then return end
        local countItem, source = recoveryInventory()
        if countItem then
            for _, candidate in ipairs(FC.Queue.GetJobs()) do
                if candidate.status == "uncertain" then
                    for _, failed in ipairs(candidate.tasks or {}) do
                        if reconcileSavedCraft(candidate, failed, countItem, source) then
                            message(L.execReconciled)
                            return
                        end
                    end
                end
            end
        end
        local profession = currentProfession()
        local job, task = FC.Queue.NextTask(profession)
        if task and task.status == "uncertain" then recoverFromBags(job) end
    end)
end

function Execution.ReplanFromBags(job)
    local replacement, text = recoverFromBags(job)
    if not replacement then return message(text) end
    return true, text, replacement
end

function Execution.ReconcileUncertain(preferredJob)
    if active then return message(L.execBusy) end
    local job, task
    if preferredJob then
        if FC.Queue.GetJob(preferredJob.id) ~= preferredJob then return message(L.execNothingToReview) end
        job = preferredJob
        for _, candidate in ipairs(job.tasks or {}) do
            if candidate.status == "uncertain" then task = candidate; break end
        end
    else
        job, task = FC.Queue.NextTask()
    end
    if not task or task.status ~= "uncertain" or job.status ~= "uncertain" then return message(L.execNothingToReview) end
    if job.characterKey ~= FC.state.characterKey or job.build ~= tostring(FC.state.build) then
        return message(L.execWrongActor)
    end
    local countItem, source = recoveryInventory()
    if reconcileSavedCraft(job, task, countItem, source) then
        return message(L.execReconciled)
    end
    if L.execReplanSuggested and Execution.CanReplanFromBags(job) then
        return message(L.execReplanSuggested)
    end
    return message(L.execUnproved)
end

function Execution.InventoryChanged(status, context)
    local regions = context and context.regions
    if regions and regions.professions then
        refreshSoon()
        if switching then later(0, checkSwitch) end
    end
    if status and status.handover and nativeHandoff then
        clearNativeHandoff()
        message(L.execProviderChanged)
    elseif nativeHandoff and nativeHandoff.requireWhole and (not regions or regions.bags)
        and FC.InventoryAdapter.GetStatus().reliable and not jobInputsCarried(nativeHandoff.expectedJob) then
        clearNativeHandoff()
        message(L.execMissingMaterials)
    end
    if status and status.handover and active then
        stopActive(active, L.execProviderChanged, false)
    else
        reconcileObserved(active)
    end
    FC:Emit("INVENTORY_CHANGED", status, context)
    scheduleRecovery()
end

local function recordExecution(request, key, count, quantity)
    local total = (request.resultMatches or 0) + count
    if request.seen[key] or total > request.batch then return end
    request.seen[key] = true
    request.resultMatches = total
    if quantity then request.resultQuantity = (request.resultQuantity or 0) + quantity end
    if total > request.matched then
        local additional = total - request.matched
        request.matched = total
        -- Carried/chat and native receipts can describe the same result.
        local output = quantity and request.resultQuantity - (request.evidence.reportedOutput or 0)
        FC.Queue.CraftEvent(request.job, request.task, additional, output)
    end
    reconcileObserved(request)
end

local function validPlayerCast(unit, castGUID, spellID)
    return safe(unit) and unit == "player" and safe(castGUID) and type(castGUID) == "string"
        and castGUID ~= "" and safe(spellID) and type(spellID) == "number"
end

local function observeCraftCast(unit, castGUID, spellID, sent)
    if not validPlayerCast(unit, castGUID, spellID) or recentCastGUIDs[castGUID] then return end
    local request = activeSession()
    if request and request.classicReceipt and not request.recipeSpellID and not sent and UnitCastingInfo then
        local name, display, _, _, _, tradeSkill, guid, _, nativeID = UnitCastingInfo("player")
        if safe(tradeSkill) and tradeSkill == true and safe(guid) and guid == castGUID and safe(nativeID)
            and nativeID == spellID and (safe(name) and name == request.classicName
                or safe(display) and display == request.classicName) then
            -- Learn the cast identity for this native click without changing the saved recipe key.
            request.recipeSpellID = spellID
        end
    end
    if request and not request.ending and request.recipeSpellID == spellID then
        if sent then request.sentCastGUID = castGUID
        else
            request.castGUID, request.interruptedCastGUID, request.stoppedCastGUID = castGUID, nil, nil
            FC:Emit("CRAFT_CAST_CHANGED")
        end
        return
    end
    local handoff = nativeHandoff
    if handoff and handoff.nativeEntry and handoff.recipeSpellID == spellID and Execution.GetNativeCraftRecipe() then
        handoff.nativeEntry.castGUID = castGUID
    end
end

local function spellcastSuccess(unit, castGUID, spellID)
    if not validPlayerCast(unit, castGUID, spellID) then return end
    local request = activeSession()
    if not request or request.resultAttributionLost or spellID ~= request.recipeSpellID
        or (request.classicReceipt and castGUID ~= request.castGUID)
        or (request.castGUID and castGUID ~= request.castGUID) or not rememberPlayerCast(castGUID) then return end
    request.stoppedCastGUID = castGUID
    request.castGUID, request.sentCastGUID = nil, nil
    if request.classicReceipt then
        if request.castSuccesses < request.batch then request.castSuccesses = request.castSuccesses + 1 end
        reconcileObserved(request)
    elseif request.kind == "classic" then
        recordExecution(request, castGUID, 1)
    elseif request.kind == "forever" and not request.castAttributionLost then
        if request.castSuccesses == request.batch then
            request.castAttributionLost = true
            request.evidence.stockAttributionLost = true
            return
        end
        request.castSuccesses = request.castSuccesses + 1
        request.evidence.exactPlayerCastCount = request.castSuccesses
        reconcileObserved(request)
    end
    if active == request then FC:Emit("CRAFT_CAST_CHANGED") end
end

local function observeCastStop(unit, castGUID, spellID)
    local request = activeSession()
    if not request or not validPlayerCast(unit, castGUID, spellID) or spellID ~= request.recipeSpellID
        or castGUID ~= (request.castGUID or request.stoppedCastGUID) then return end
    request.stoppedCastGUID = castGUID
    if not reconcileObserved(request) then FC:Emit("CRAFT_CAST_CHANGED") end
end

local function matchingResult(result, itemID, minimum)
    return safe(result) and type(result) == "table" and safe(result.itemID) and safe(result.quantity)
        and result.itemID == itemID and type(result.quantity) == "number"
        and result.quantity >= minimum and result.quantity % 1 == 0
        and not result.bonusCraft and not result.isEnchant and not result.firstCraftReward
end

function modernResult(result, earlyBegins)
    local request = activeSession()
    if not request or request.kind ~= "forever" or request.begins == 0 or request.resultAttributionLost
        or not matchingResult(result, request.task.outputItemID, request.task.yield) then return end
    local count = 1
    if request.maxYield == request.task.yield then
        if result.quantity % request.task.yield ~= 0 then return end
        count = result.quantity / request.task.yield
    elseif result.quantity > request.maxYield then
        return -- aggregate executions with variable yield cannot be separated from this result
    end
    local operation = result.operationID
    if not safe(operation) then return end
    local key = type(operation) == "number" and operation > 0 and operation or ("begin" .. (earlyBegins or request.begins))
    recordExecution(request, key, count, result.quantity)
end

local creationPatterns
local function addCreationPatterns(patterns, formatText, multiple)
    if type(formatText) ~= "string" then return end
    local prefix, alternatives, suffix = formatText:match("^(.-)|[14]([^;]*);(.*)$")
    if alternatives then
        for alternative in (alternatives .. ":"):gmatch("(.-):") do
            addCreationPatterns(patterns, prefix .. alternative .. suffix, multiple)
        end
        return
    end
    local fields, linkIndex, countIndex = 0, nil, nil
    local template = formatText:gsub("%%[%d$]*([sd])", function(kind)
        fields = fields + 1
        if kind == "s" then linkIndex = fields else countIndex = fields end
        return kind == "s" and "\001" or "\002"
    end)
    if not linkIndex or multiple and not countIndex or fields ~= (multiple and 2 or 1) then return end
    local pattern = template:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1")
        :gsub("\001", "(.+)"):gsub("\002", "(%%d+)")
    patterns[#patterns + 1] = {pattern = "^" .. pattern .. "$", linkIndex = linkIndex, countIndex = countIndex}
end

local function createdItem(message)
    if not creationPatterns then
        creationPatterns = {}
        addCreationPatterns(creationPatterns, LOOT_ITEM_CREATED_SELF, false)
        addCreationPatterns(creationPatterns, LOOT_ITEM_CREATED_SELF_MULTIPLE, true)
    end
    for _, entry in ipairs(creationPatterns) do
        local fields = {message:match(entry.pattern)}
        local link = fields[entry.linkIndex]
        local itemID = link and tonumber(link:match("|Hitem:(%d+)[^|]*|h"))
        if itemID then return itemID, entry.countIndex and tonumber(fields[entry.countIndex]) or 1 end
    end
end

local function observeCreatedItem(message, lineID, guid)
    local request = activeSession()
    if not request or request.resultAttributionLost or request.castAttributionLost
        or not (request.classicReceipt or request.directReceipt or request.nativeReceipt) or request.createdOutputInvalid
        or not safe(message) or type(message) ~= "string" or not safe(lineID)
        or type(lineID) ~= "number" or lineID < 1 or not safe(guid) then return end
    if guid and guid ~= "" and UnitGUID then
        local player = UnitGUID("player")
        if not safe(player) or guid ~= player then return end
    end
    local itemID, count = createdItem(message)
    if itemID ~= request.task.outputItemID or not count or count < 1 then return end
    request.createdLines = request.createdLines or {}
    if request.createdLines[lineID] then return end
    request.createdLines[lineID] = true
    request.createdOutput = (request.createdOutput or 0) + count
    if request.createdOutput > request.batch * request.maxYield then
        request.createdOutputInvalid = true
    else
        reconcileObserved(request)
    end
end

local events = CreateFrame("Frame")
local playerCastEnds = {
    UNIT_SPELLCAST_STOP = true,
    UNIT_SPELLCAST_INTERRUPTED = true,
    UNIT_SPELLCAST_FAILED = true,
    UNIT_SPELLCAST_FAILED_QUIET = true,
}
local names = {
    "TRADE_SKILL_SHOW", "TRADE_SKILL_CLOSE", "TRADE_SKILL_LIST_UPDATE", "TRADE_SKILL_UPDATE",
    "TRADE_SKILL_DATA_SOURCE_CHANGING", "TRADE_SKILL_DATA_SOURCE_CHANGED",
    "NEW_RECIPE_LEARNED", "SKILL_LINES_CHANGED", "UNIT_SPELLCAST_SUCCEEDED",
    "UNIT_SPELLCAST_START", "UNIT_SPELLCAST_SENT", "UNIT_SPELLCAST_DELAYED", "UNIT_SPELLCAST_STOP",
    "UNIT_SPELLCAST_INTERRUPTED", "UNIT_SPELLCAST_FAILED",
    "UNIT_SPELLCAST_FAILED_QUIET", "TRADE_SKILL_CRAFT_BEGIN",
    "TRADE_SKILL_ITEM_CRAFTED_RESULT", "UPDATE_TRADESKILL_CAST_STOPPED",
    "ADDON_ACTION_BLOCKED", "ADDON_ACTION_FORBIDDEN", "BAG_UPDATE_DELAYED", "CHAT_MSG_LOOT", "PLAYER_REGEN_ENABLED",
}
for _, event in ipairs(names) do pcall(events.RegisterEvent, events, event) end
events:SetScript("OnEvent", function(_, event, a, b, c, d, ...)
    if FC.state.ready == false then return end
    if restockIdleBlocked and (event == "UPDATE_TRADESKILL_CAST_STOPPED"
        or playerCastEnds[event] and safe(a) and a == "player") then
        wakeRestockWhenIdle()
    end
    if event == "TRADE_SKILL_DATA_SOURCE_CHANGING" or event == "TRADE_SKILL_CLOSE" then
        local cancelledHandoff = nativeHandoff ~= nil
        clearNativeHandoff()
        generation = generation + 1
        changing = event == "TRADE_SKILL_DATA_SOURCE_CHANGING"
        if cancelledHandoff then message(L.execClosed) end
        stopActive(active, L.execClosed, true)
        refreshSoon()
    elseif event == "TRADE_SKILL_SHOW" or event == "TRADE_SKILL_LIST_UPDATE"
        or event == "TRADE_SKILL_UPDATE" or event == "TRADE_SKILL_DATA_SOURCE_CHANGED" then
        if event == "TRADE_SKILL_DATA_SOURCE_CHANGED" or event == "TRADE_SKILL_SHOW" then changing = false end
        local open, counter = currentProfession()
        if active and open and (tonumber(open) ~= tonumber(active.task.professionId)
            or (counter ~= nil and counter ~= active.sourceCounter)) then
            generation = generation + 1
            stopActive(active, L.execClosed, true)
        end
        later(0, checkSwitch)
        refreshSoon()
    elseif event == "NEW_RECIPE_LEARNED" or event == "SKILL_LINES_CHANGED" then
        refreshSoon()
    elseif event == "TRADE_SKILL_CRAFT_BEGIN" then
        local request = activeSession()
        local pending = nativeHandoff
        if not request and pending and pending.nativeEntry and Execution.GetNativeCraftRecipe() then
            local entry = pending.nativeEntry
            if safe(a) and a == pending.recipeSpellID then
                entry.begins = entry.begins + 1
            else
                entry.mismatch = true
            end
        elseif request and request.kind == "forever" then
            if not request.ending and safe(a) and a == request.recipeSpellID and request.begins < request.batch then
                request.begins = request.begins + 1
            elseif not safe(a) or a ~= request.recipeSpellID or request.begins >= request.batch then
                request.castAttributionLost = true
                request.evidence.stockAttributionLost = true
                if request.begins > 0 or request.castSuccesses > 0 then
                    -- The result payload has no recipe ID. A new craft can produce the same item.
                    request.resultAttributionLost = true
                    stopActive(request, L.execUnproved, false)
                end
            end
        end
    elseif event == "TRADE_SKILL_ITEM_CRAFTED_RESULT" then
        local pending = nativeHandoff
        local entry = pending and pending.nativeEntry
        if entry and not entry.mismatch and entry.begins > 0 and #entry.results < pending.recipeSelection.batch
            and matchingResult(a, entry.itemID, entry.yield) and Execution.GetNativeCraftRecipe() then
            entry.results[#entry.results + 1] = {result = a, begins = entry.begins}
        else
            modernResult(a)
        end
    elseif event == "UNIT_SPELLCAST_START" then
        observeCraftCast(a, b, c)
    elseif event == "UNIT_SPELLCAST_SENT" then
        observeCraftCast(a, c, d, true)
    elseif event == "UNIT_SPELLCAST_DELAYED" then
        local request = activeSession()
        if request and validPlayerCast(a, b, c) and c == request.recipeSpellID and b == request.castGUID then
            FC:Emit("CRAFT_CAST_CHANGED")
        end
    elseif event == "UNIT_SPELLCAST_STOP" then
        observeCastStop(a, b, c)
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        spellcastSuccess(a, b, c)
    elseif event == "CHAT_MSG_LOOT" then
        observeCreatedItem(a, select(7, ...))
    elseif event == "UNIT_SPELLCAST_INTERRUPTED" or event == "UNIT_SPELLCAST_FAILED" or event == "UNIT_SPELLCAST_FAILED_QUIET" then
        local request = activeSession()
        if not request or not validPlayerCast(a, b, c) or c ~= request.recipeSpellID or recentCastGUIDs[b] then return end
        if request.kind == "forever" or request.classicReceipt then
            if b ~= request.castGUID and (request.castGUID or b ~= request.sentCastGUID) then return end
            request.interruptedCastGUID, request.stoppedCastGUID = b, b
        elseif event == "UNIT_SPELLCAST_FAILED_QUIET" then return end
        request.nativeInterrupted = true
        observeTerminal(request)
    elseif event == "UPDATE_TRADESKILL_CAST_STOPPED" then
        if not active then scheduleRecovery() end
        if safe(a) and a == false then observeTradeStop(activeSession()) end
    elseif event == "ADDON_ACTION_BLOCKED" or event == "ADDON_ACTION_FORBIDDEN" then
        if safe(a) and a == FC.name then
            local request = active
            if request and request.directDispatch and safe(b) and type(b) == "string" then
                local action = b:gsub("%(%)$", "")
                if action == "C_TradeSkillUI.CraftRecipe" or action == "CraftRecipe" then
                    if request.invokingDirect then
                        request.directDenied = true
                    elseif not abortDeniedDirectCraft(request) then
                        stopActive(request, L.execBlockedByClient, true)
                    end
                end
                return
            end
            if nativeHandoff then clearNativeHandoff(); message(L.execBlockedByClient) end
            stopActive(active, L.execBlockedByClient, true)
        end
    elseif event == "BAG_UPDATE_DELAYED" then
        reconcileObserved(active)
        scheduleRecovery()
    elseif event == "PLAYER_REGEN_ENABLED" then
        scheduleRecovery()
    end
end)

FC:On("QUEUE_CHANGED", function()
    local job = nativeHandoff and nativeHandoff.expectedJob
    if job and (job.status ~= "queued" or FC.Queue.GetJob(job.id) ~= job or FC.Queue.IsClearing(job)
        or job.invalidatedAfterAction) then
        clearNativeHandoff()
        message(L.execRecipeChanged)
    end
    scheduleRecovery()
end)

FC:On("READY", function()
    FC.InventoryAdapter.Start(Execution.InventoryChanged)
    if EventRegistry and type(EventRegistry.RegisterCallback) == "function" then
        -- The native confirmation can precede the persisted roster change.
        EventRegistry:RegisterCallback("Professions.SkillAbandoned", refreshSoon, Execution)
    end
    refresh()
end)
