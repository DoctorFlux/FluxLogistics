local _, FC = ...
local L = FC.L
local Diagnostics = {}
FC.Diagnostics = Diagnostics

local function lastCraft()
    local newest, jobID, task
    for _, job in ipairs(FC.Queue.GetJobs()) do
        for _, candidate in ipairs(job.tasks or {}) do
            local evidence = candidate.evidence
            local stamp = evidence and evidence.startedAt
            if type(stamp) == "number" and (not newest or stamp >= newest) then
                newest, jobID, task = stamp, job.id, candidate
            end
        end
    end
    return jobID, task
end

local function lastAcquisition()
    local selectedJob, selectedAction, selectedRequirement
    for _, job in ipairs(FC.Queue.GetJobs()) do
        local action = job.acquisition or job.lastAcquisition
        local requirement = action and job.requirements and job.requirements[action.index]
        if requirement and type(action.startedAt) == "number" and (not selectedAction
            or action.startedAt > selectedAction.startedAt
            or action.startedAt == selectedAction.startedAt and job.id > selectedJob.id) then
            selectedJob, selectedAction, selectedRequirement = job, action, requirement
        end
    end
    return selectedJob, selectedAction, selectedRequirement
end

local function actionVersion(evidence)
    if not evidence.addonVersion or not evidence.clientBuild then return "" end
    return L.diagnosticActionVersion:format(evidence.addonVersion, evidence.clientBuild)
end

function Diagnostics.Lines()
    local state = FC.state
    if not state.ready then return {L.diagnosticWaiting} end
    local inv = FC.InventoryAdapter.GetStatus()
    local catalog = FC.Catalog.Snapshot()
    local options = FC.Logistics.GetSettings()
    local complete, known = 0, 0
    for _, recipe in pairs(catalog.recipesById) do
        if recipe.learned == true then
            known = known + 1
            if recipe.completeness == "complete" then complete = complete + 1 end
        end
    end
    local market = options.provider or "auto"
    local owner = Flux and Flux.RestockPolicy
    local current = FC.Clients.CurrentProfessionID()
    local lines = {
        L.diagnosticBuild:format(FC.version, FC.target, tostring(state.clientBuild), tostring(state.build), state.db.schema),
        L.diagnosticInventory:format(inv.source or L.unknown, inv.reliable and L.diagnosticReady or
            inv.reason or L.diagnosticWaiting, FC.InventoryAdapter.GetRevision(), FC.Logistics.MailboxStatus()),
        L.diagnosticCatalog:format(complete, known, tostring(catalog.revision), tostring(current or L.unknown)),
        L.diagnosticServices:format(market, #FC.Queue.GetJobs(), FC.Queue.GetRevision(),
            tostring(owner and owner.version or L.unknown)),
    }
    local ui = FC.UI
    local plan = ui and (ui.job or ui.preview)
    if plan then
        lines[#lines + 1] = L.diagnosticPlan:format(L[plan.status] or plan.status or L.unknown,
            tostring(plan.rootRecipeId or L.unknown), plan.blocker or ui.message or "")
    end
    local jobID, task = lastCraft()
    if task then
        local evidence = task.evidence
        lines[#lines + 1] = L.diagnosticCraft:format(jobID, tostring(task.recipeId), L[task.status] or task.status,
            tostring(evidence.matchedExecutions or 0), tostring(evidence.beforeOutput or L.unknown),
            tostring(evidence.afterOutput or L.unknown)) .. actionVersion(evidence)
    end
    local acquisitionJob, action, requirement = lastAcquisition()
    if action then
        local required = requirement.quantity or 0
        local carried = required - (requirement.remaining or required)
        local kind = action.kind or requirement.kind
        lines[#lines + 1] = L.diagnosticAcquisition:format(acquisitionJob.id, kind, L[action.status] or action.status,
            L.item:format(requirement.itemID), action.quantity, carried, required, requirement.auctionAwaiting or 0)
            .. actionVersion(action)
    end
    if state.lastError then lines[#lines + 1] = L.diagnosticError:format(state.lastError:sub(1, 240)) end
    return lines
end

function Diagnostics.Print()
    for _, line in ipairs(Diagnostics.Lines()) do print(line) end
end
