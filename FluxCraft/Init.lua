local addonName, FC = ...

FC.name = addonName
FC.version = "0.2.71-dev"
FC.state = FC.state or { ready = false }
FC.listeners = FC.listeners or {}

function FC:On(event, callback)
    if type(event) ~= "string" or type(callback) ~= "function" then
        return nil
    end
    if event == "READY" and self.state.ready then
        callback(self)
        return function() end
    end
    local listeners = self.listeners[event]
    if not listeners then
        listeners = {}
        self.listeners[event] = listeners
    end
    listeners[#listeners + 1] = callback
    return function()
        for index = #listeners, 1, -1 do
            if listeners[index] == callback then
                table.remove(listeners, index)
                break
            end
        end
    end
end

function FC:Emit(event, ...)
    local listeners = self.listeners[event]
    if not listeners then return end
    for index = 1, #listeners do
        local ok, err = pcall(listeners[index], self, ...)
        if not ok then
            self.state.lastError = type(err) == "string" and err or nil
            if geterrorhandler then geterrorhandler()(err) end
        end
    end
end

local function characterKey()
    local guid = UnitGUID and UnitGUID("player")
    if guid and guid ~= "" then return guid end
    local name = UnitName and UnitName("player") or "Unknown"
    local realm = GetNormalizedRealmName and GetNormalizedRealmName()
    if not realm or realm == "" then
        realm = GetRealmName and GetRealmName() or "Unknown"
    end
    return tostring(name) .. "-" .. tostring(realm)
end

local function copySaved(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, child in pairs(value) do result[key] = copySaved(child) end
    return result
end

local function migrate(current, previous)
    if type(current) == "table" then return current end
    return type(previous) == "table" and copySaved(previous) or {}
end

local function initializeSavedVariables()
    local db = migrate(_G.FluxLogisticsDB, _G.FluxCraftDB)
    local char = migrate(_G.FluxLogisticsCharDB, _G.FluxCraftCharDB)
    if (tonumber(db.schema) or 0) > 2 or (tonumber(char.schema) or 0) > 2 then
        if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage(FC.L.newerSave) end
        return false
    end
    _G.FluxLogisticsDB, _G.FluxLogisticsCharDB = db, char
    db.schema = 2
    char.schema = 2
    db.catalog = type(db.catalog) == "table" and db.catalog or {}
    db.catalog.characters = type(db.catalog.characters) == "table" and db.catalog.characters or {}

    local key = characterKey()
    local version, clientBuild, _, interface = GetBuildInfo()
    interface = tonumber(interface) or 0
    local character = db.catalog.characters[key]
    if type(character) ~= "table" then
        character = {}
        db.catalog.characters[key] = character
    end
    character.builds = type(character.builds) == "table" and character.builds or {}
    local build = character.builds[interface]
    if type(build) ~= "table" then
        build = {}
        character.builds[interface] = build
    end
    build.professions = type(build.professions) == "table" and build.professions or {}
    build.clientBuild = clientBuild
    build.clientVersion = version

    local state = FC.state
    state.db = db
    state.char = char
    state.characterKey = key
    state.build = interface
    state.clientBuild = clientBuild
    state.catalogBuildStore = build
    state.catalogStore = build.professions
    state.actor = {
        key = key, client = FC.target, interface = interface,
        region = GetCurrentRegion and GetCurrentRegion(),
        realm = GetRealmID and GetRealmID() or (GetRealmName and GetRealmName()),
    }
    char.characterKey = key
    char.build = interface

    return true
end

local function start()
    if FC.state.ready or not initializeSavedVariables() then return end
    if FC.Queue and FC.Queue.Initialize then
        FC.Queue.Initialize(FC.state.char)
    end
    FC.state.ready = true
    FC:Emit("READY")
end

if FC.disabled then return end
local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")
events:SetScript("OnEvent", function(_, event, loadedAddon)
    if event == "PLAYER_LOGIN" or (loadedAddon == addonName and IsLoggedIn and IsLoggedIn()) then start() end
end)
