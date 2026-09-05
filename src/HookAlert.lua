--
-- Script Sentry
--
-- Startup-review observer for live Lua function overlap and general GUI
-- integrity problems.
--
-- Important design boundary: this mod never replaces source(), a watched
-- gameplay target, or any input function. While mods initialize it temporarily
-- observes calls to GIANTS' wrapper-construction helpers, forwarding every call
-- unchanged to the original helper. It restores those helpers after the startup
-- scan finishes.
-- It never resolves, reorders, mutes, persists, or exposes a conflict-management
-- interface. Version 0.5.4 also observes mod specialization registration and
-- the resulting type-function slots without wrapping any gameplay callback.
-- Version 0.5.3 also provides a safe, on-demand frame-rate check
-- which does not insert Script Sentry into gameplay callback chains.
--

HookAlert = {}
local HookAlert_mt = Class(HookAlert)

local OWNER_GIANTS = "GIANTS base game"
local OWNER_ENGINE = "engine/C++"
local OWNER_UNKNOWN = "unknown provider"
local OWNER_UNKNOWN_REMOVER = "unknown remover"
local SCRIPT_SENTRY_VERSION = "0.5.4.0"
local MAX_PLAYER_ITEMS = 3
local unpackValues = unpack or table.unpack

local function packValues(...)
    return {n = select("#", ...), ...}
end

local INFRASTRUCTURE_PATHS = {
    ["source"] = true,
    ["addModEventListener"] = true,
    ["Utils.appendedFunction"] = true,
    ["Utils.prependedFunction"] = true,
    ["Utils.overwrittenFunction"] = true,
    ["MultiTextOptionElement.setTexts"] = true,
    ["GuiElement.clone"] = true,
    ["GuiElement.exposeControlsAsFields"] = true,
    ["SpecializationManager.addSpecialization"] = true,
    ["SpecializationUtil.registerEventListener"] = true,
    ["SpecializationUtil.removeEventListener"] = true,
    ["SpecializationUtil.registerFunction"] = true,
    ["SpecializationUtil.registerOverwrittenFunction"] = true
}

local PREVIOUS_UPVALUE_NAMES = {
    oldfunc = true,
    oldfunction = true,
    originalfunc = true,
    originalfunction = true,
    previousfunc = true,
    previousfunction = true,
    superfunc = true,
    superfunction = true
}

local HOOK_UPVALUE_NAMES = {
    hookfunc = true,
    hookfunction = true,
    newfunc = true,
    newfunction = true
}

local function normalizeName(name)
    return string.lower(string.gsub(tostring(name or ""), "[^%a]", ""))
end

local function isMod(owner)
    return owner ~= nil
        and owner ~= OWNER_GIANTS
        and owner ~= OWNER_ENGINE
        and owner ~= OWNER_UNKNOWN
        and owner ~= OWNER_UNKNOWN_REMOVER
end

local function count(values)
    local result = 0
    for _ in pairs(values or {}) do
        result = result + 1
    end
    return result
end

local function sortedNames(values)
    local names = {}
    for name in pairs(values or {}) do
        table.insert(names, name)
    end
    table.sort(names)
    return names
end

local function joinedNames(values)
    return table.concat(sortedNames(values), " + ")
end

function HookAlert.new(modDirectory, modName, customMt)
    local self = setmetatable({}, customMt or HookAlert_mt)
    self.modDirectory = modDirectory
    self.modName = modName
    self.hud = HookAlertHud.new()
    self.performance = PerformanceMonitor.new(modDirectory, modName)
    self.uiIntegrity = UiIntegrityMonitor.new(self, modName)
    self.snapshot = {}
    self.ownerBySlot = {}
    self.participantsBySlot = {}
    self.issues = {}
    self.issueOrder = {}
    self.runtimeMs = 0
    self.scanAccumulator = 0
    self.scanInterval = 1500
    self.runtimeScanInterval = 5000
    self.uiScanAccumulator = 0
    self.uiScanInterval = 1500
    self.summarySent = false
    self.installed = false
    self.canInspectClosures = debug ~= nil and type(debug.getupvalue) == "function"
    self.canReadFunctionEnvironment = type(getfenv) == "function"
    self.canObserveWrappers = false
    self.ownerAttributionObserved = false
    self.currentLoadOwner = nil
    self.currentLoadOwnerObservedAt = nil
    self.ownerClock = type(getTimeSec) == "function" and getTimeSec or nil
    self.wrapperRecords = {}
    self.wrapperOrder = {}
    self.wrapperSequence = 0
    self.objectTypeLabels = {}
    self.objectTypeSequence = 0
    self.typeFunctionRecords = {}
    self.typeFunctionOrder = {}
    self.eventListenerRecords = {}
    self.eventListenerOrder = {}
    self.specializationSnapshots = {}
    self.specializationSnapshotOrder = {}
    self.specializationFunctionOwners = {}
    self.observedHelpers = {}
    self.helpersRestored = false
    self.missionReady = false
    self.summaryDelay = 12000
    self.actionEventId = nil
    self.performanceActionEventId = nil
    self.actionEventsRegistered = false
    return self
end

function HookAlert:log(message, ...)
    if select("#", ...) > 0 then
        message = string.format(message, ...)
    end
    print("[ScriptSentry] " .. message)
end

function HookAlert:install()
    if self.installed then
        return
    end
    self.installed = true

    -- UI mutators become part of the baseline snapshot. Script Sentry therefore
    -- does not report its own read-only tracing wrappers as function conflicts.
    self.uiIntegrity:install()
    self.snapshot = self:collectSlots()
    for path, func in pairs(self.snapshot) do
        local owner = self:getFunctionOwner(func)
        if owner == OWNER_UNKNOWN then
            owner = OWNER_GIANTS
        end
        self.ownerBySlot[path] = owner
        self.participantsBySlot[path] = {}
    end

    self:installHelperObservation()
    self.performance:install()

    if self.canInspectClosures then
        self:log("v%s active - confirmed-conflict review and safe FPS checks available", SCRIPT_SENTRY_VERSION)
    elseif self.canObserveWrappers then
        self:log("v%s active - confirmed-conflict review and safe FPS checks; debug library not required", SCRIPT_SENTRY_VERSION)
    else
        self:log("WARNING: no supported function-chain observer is available")
    end
end

function HookAlert:getModNameFromPath(filename)
    if type(filename) ~= "string" then
        return nil
    end

    local normalized = string.gsub(filename, "\\", "/")
    return string.match(normalized, "/mods/([^/]+)%.zip/")
        or string.match(normalized, "/mods/([^/]+)/")
        or string.match(normalized, "^mods/([^/]+)%.zip/")
        or string.match(normalized, "^mods/([^/]+)/")
end

function HookAlert:getFunctionOwner(func)
    if type(func) ~= "function" then
        return OWNER_UNKNOWN, nil
    end

    if self.uiIntegrity ~= nil and type(self.uiIntegrity.getWrappedOriginal) == "function" then
        local original = self.uiIntegrity:getWrappedOriginal(func)
        if type(original) == "function" and original ~= func then
            return self:getFunctionOwner(original)
        end
    end

    if self.performance ~= nil then
        local wrappedOwner = self.performance:getWrappedOwner(func)
        if isMod(wrappedOwner) then
            return wrappedOwner, nil
        end
    end

    if self.canReadFunctionEnvironment then
        local ok, environment = pcall(getfenv, func)
        if ok and type(environment) == "table" then
            local environmentOwner = rawget(environment, "g_currentModName")
            local environmentDirectory = rawget(environment, "g_currentModDirectory")
            if type(environmentOwner) == "string" and environmentOwner ~= "" then
                return environmentOwner, environmentDirectory
            end
        end
    end

    local sourceName = nil
    if debug ~= nil and debug.getinfo ~= nil then
        local ok, info = pcall(debug.getinfo, func, "S")
        if ok and info ~= nil then
            sourceName = info.source or info.short_src
        end
    end

    if sourceName ~= nil then
        sourceName = string.gsub(sourceName, "^@", "")
        local owner = self:getModNameFromPath(sourceName)
        if owner ~= nil then
            return owner, sourceName
        end

        local normalized = string.lower(string.gsub(sourceName, "\\", "/"))
        if string.find(normalized, "/datas/", 1, true) ~= nil
            or string.find(normalized, "data/scripts/", 1, true) ~= nil then
            return OWNER_GIANTS, sourceName
        end
        if sourceName == "=[C]" or sourceName == "[C]" then
            return OWNER_ENGINE, sourceName
        end
    end

    return OWNER_UNKNOWN, sourceName
end

function HookAlert:observeModDirectory(directory)
    local owner = self:getModNameFromPath(directory)
    if owner ~= nil and owner ~= self.modName then
        self.currentLoadOwner = owner
        self.currentLoadOwnerObservedAt = self.ownerClock ~= nil and self.ownerClock() or nil
        if self.performance ~= nil then
            self.performance:setCurrentOwner(owner)
        end
    end
end

function HookAlert:getUiMutationOwner()
    if self.performance ~= nil and type(self.performance.getExecutingOwner) == "function" then
        local owner = self.performance:getExecutingOwner()
        if isMod(owner) and owner ~= self.modName then
            return owner
        end
    end

    -- FS25 release builds may expose neither debug.getinfo nor getfenv. During
    -- mod initialization, Utils.getFilename still gives us an exact, recent
    -- mod directory. Use it only for a very short window so an old load owner
    -- is never carried into unrelated gameplay.
    if self.ownerClock ~= nil
        and self.currentLoadOwnerObservedAt ~= nil
        and isMod(self.currentLoadOwner)
        and self.currentLoadOwner ~= self.modName then
        local age = self.ownerClock() - self.currentLoadOwnerObservedAt
        if age >= 0 and age <= 0.25 then
            return self.currentLoadOwner
        end
    end
    return nil
end

function HookAlert:getObservedOwner(hookFunc)
    local capturedOwner = self.specializationFunctionOwners[hookFunc]
    if isMod(capturedOwner) and capturedOwner ~= self.modName then
        return capturedOwner
    end
    local owner = self:getFunctionOwner(hookFunc)
    if isMod(owner) and owner ~= self.modName then
        return owner
    end
    if owner == OWNER_GIANTS or owner == OWNER_ENGINE then
        return owner
    end
    if isMod(self.currentLoadOwner) and self.currentLoadOwner ~= self.modName then
        return self.currentLoadOwner
    end
    return OWNER_UNKNOWN
end

function HookAlert:recordWrapper(kind, wrappedFunc, previousFunc, hookFunc, observedOwner)
    if type(wrappedFunc) ~= "function" or type(previousFunc) ~= "function" then
        return
    end

    self.wrapperSequence = self.wrapperSequence + 1
    local previousRecord = self.wrapperRecords[previousFunc]
    local owner = observedOwner or self:getObservedOwner(hookFunc)
    local record = {
        kind = kind,
        resultFunc = wrappedFunc,
        previousFunc = previousFunc,
        hookFunc = hookFunc,
        owner = owner,
        sequence = self.wrapperSequence,
        rootFunc = previousRecord ~= nil and previousRecord.rootFunc or previousFunc
    }
    self.wrapperRecords[wrappedFunc] = record
    table.insert(self.wrapperOrder, record)
    if isMod(owner) then
        self.ownerAttributionObserved = true
    end
end

function HookAlert:getObjectTypeLabel(objectType)
    local label = self.objectTypeLabels[objectType]
    if label ~= nil then
        return label
    end

    self.objectTypeSequence = self.objectTypeSequence + 1
    local typeName = type(objectType) == "table"
        and (objectType.name or objectType.typeName)
        or nil
    label = string.format(
        "$objectType[%s#%d]",
        tostring(typeName or "unnamed"),
        self.objectTypeSequence
    )
    self.objectTypeLabels[objectType] = label
    return label
end

function HookAlert:getTypeFunctionPath(objectType, functionName)
    return self:getObjectTypeLabel(objectType)
        .. ".functions."
        .. tostring(functionName or "unknown")
end

function HookAlert:getEventListenerPath(objectType, eventName, owner)
    return self:getObjectTypeLabel(objectType)
        .. ".eventListeners."
        .. tostring(eventName or "unknown")
        .. "."
        .. tostring(owner or OWNER_UNKNOWN)
end

function HookAlert:hasEventListener(objectType, eventName, spec)
    local listeners = type(objectType) == "table"
        and type(objectType.eventListeners) == "table"
        and objectType.eventListeners[eventName]
        or nil
    if type(listeners) ~= "table" then
        return false
    end
    for _, registeredSpec in pairs(listeners) do
        if registeredSpec == spec then
            return true
        end
    end
    return false
end

function HookAlert:recordTypeFunctionRegistration(objectType, functionName, hookFunc, beforeFunc, afterFunc, owner)
    if type(objectType) ~= "table"
        or type(objectType.functions) ~= "table"
        or type(afterFunc) ~= "function" then
        return
    end

    local resolvedOwner = owner
    if not isMod(resolvedOwner) then
        resolvedOwner = self.specializationFunctionOwners[hookFunc]
            or self.specializationFunctionOwners[afterFunc]
            or self:getFunctionOwner(hookFunc or afterFunc)
    end

    local path = self:getTypeFunctionPath(objectType, functionName)
    -- GIANTS registers thousands of base type functions through the same
    -- helper. Keep only mod-owned registrations (or a slot already being
    -- followed) so the passive audit remains small and actionable.
    if self.typeFunctionRecords[path] == nil and not isMod(resolvedOwner) then
        return
    end

    if self.typeFunctionRecords[path] == nil then
        self.typeFunctionRecords[path] = {
            path = path,
            objectType = objectType,
            functionName = functionName
        }
        table.insert(self.typeFunctionOrder, self.typeFunctionRecords[path])
    end

    local priorSnapshot = self.snapshot[path]
    if type(priorSnapshot) == "function"
        and type(beforeFunc) == "function"
        and priorSnapshot ~= beforeFunc then
        self:inspectTransition(path, priorSnapshot, beforeFunc)
    elseif priorSnapshot == nil and type(beforeFunc) == "function" then
        self.snapshot[path] = beforeFunc
        self.ownerBySlot[path] = self:getFunctionOwner(beforeFunc)
        self.participantsBySlot[path] = self:analyzeStandaloneChain(beforeFunc)
    end

    if type(beforeFunc) == "function" and afterFunc ~= beforeFunc then
        self:inspectTransition(path, beforeFunc, afterFunc)
    end

    local participants = self:analyzeStandaloneChain(afterFunc)
    if isMod(resolvedOwner) then
        participants[resolvedOwner] = true
        self.ownerBySlot[path] = resolvedOwner
        self.ownerAttributionObserved = true
    elseif self.ownerBySlot[path] == nil then
        self.ownerBySlot[path] = self:getFunctionOwner(afterFunc)
    end
    self.participantsBySlot[path] = participants
    self.snapshot[path] = afterFunc

    if count(participants) >= 2 then
        self:raiseIssue("OVERLAP", path, resolvedOwner, OWNER_UNKNOWN, participants)
    end
end

function HookAlert:captureSpecializationClass(name, className, filename, classObject, owner)
    if type(classObject) ~= "table" or self.specializationSnapshots[classObject] ~= nil then
        return
    end

    local resolvedOwner = isMod(owner) and owner or self:getModNameFromPath(filename)
    if not isMod(resolvedOwner) then
        return
    end
    local functions = {}
    local owners = {}
    for functionName, func in pairs(classObject) do
        if type(functionName) == "string" and type(func) == "function" then
            functions[functionName] = func
            local functionOwner = self:getFunctionOwner(func)
            owners[functionName] = isMod(functionOwner) and functionOwner or resolvedOwner
            if isMod(owners[functionName]) then
                self.specializationFunctionOwners[func] = owners[functionName]
            end
        end
    end
    if next(functions) == nil then
        return
    end

    local label = tostring(name or className or "specialization")
    if isMod(resolvedOwner) and string.find(label, resolvedOwner, 1, true) == nil then
        label = resolvedOwner .. "." .. label
    end
    local snapshot = {
        label = label,
        classObject = classObject,
        owner = resolvedOwner or OWNER_UNKNOWN,
        functions = functions,
        owners = owners
    }
    self.specializationSnapshots[classObject] = snapshot
    table.insert(self.specializationSnapshotOrder, snapshot)
    self.ownerAttributionObserved = true
    self:log(
        "Specialization observed: %s from %s (%d callbacks)",
        label,
        resolvedOwner,
        count(functions)
    )
end

function HookAlert:recordEventListenerRegistration(objectType, eventName, spec, owner)
    if type(objectType) ~= "table" or type(spec) ~= "table" then
        return
    end
    if not self:hasEventListener(objectType, eventName, spec) then
        return
    end
    local expectedFunc = spec[eventName]
    if type(expectedFunc) ~= "function" then
        return
    end

    local captured = self.specializationSnapshots[spec]
    local resolvedOwner = captured ~= nil and captured.owner or owner
    if not isMod(resolvedOwner) then
        resolvedOwner = self.specializationFunctionOwners[expectedFunc]
            or self:getFunctionOwner(expectedFunc)
    end
    if not isMod(resolvedOwner) then
        return
    end
    local path = self:getEventListenerPath(objectType, eventName, resolvedOwner)
    local key = path .. "|" .. tostring(spec)
    local record = self.eventListenerRecords[key]
    if record == nil then
        record = {
            path = path,
            objectType = objectType,
            eventName = eventName,
            spec = spec,
            expectedFunc = expectedFunc,
            owner = resolvedOwner or OWNER_UNKNOWN,
            removedBy = nil,
            missingScans = 0
        }
        self.eventListenerRecords[key] = record
        table.insert(self.eventListenerOrder, record)
    else
        record.expectedFunc = expectedFunc
        record.owner = resolvedOwner
        record.removedBy = nil
        record.missingScans = 0
    end

    self:captureSpecializationClass(
        resolvedOwner or "specialization",
        rawget(spec, "className"),
        nil,
        spec,
        resolvedOwner
    )
end

function HookAlert:recordEventListenerRemoval(objectType, eventName, spec, owner, wasRegistered, isRegistered)
    if not wasRegistered or isRegistered then
        return
    end

    local resolvedOwner = isMod(owner) and owner or OWNER_UNKNOWN_REMOVER
    for _, record in ipairs(self.eventListenerOrder) do
        if record.objectType == objectType
            and record.eventName == eventName
            and record.spec == spec then
            record.removedBy = resolvedOwner
            record.missingScans = 0
        end
    end
end

function HookAlert:auditSpecializationClasses()
    for _, snapshot in ipairs(self.specializationSnapshotOrder) do
        for functionName, expectedFunc in pairs(snapshot.functions) do
            local currentFunc = rawget(snapshot.classObject, functionName)
            local path = "$specialization[" .. snapshot.label .. "]." .. functionName
            if currentFunc == nil then
                self:raiseIssue("OVERWRITE", path, OWNER_UNKNOWN_REMOVER, snapshot.owners[functionName] or snapshot.owner, nil)
            elseif type(currentFunc) == "function" and currentFunc ~= expectedFunc then
                self.ownerBySlot[path] = snapshot.owners[functionName] or snapshot.owner
                self.participantsBySlot[path] = self:analyzeStandaloneChain(expectedFunc)
                self:inspectTransition(path, expectedFunc, currentFunc)
                snapshot.functions[functionName] = currentFunc
                snapshot.owners[functionName] = self.ownerBySlot[path] or self:getFunctionOwner(currentFunc)
                if isMod(snapshot.owners[functionName]) then
                    self.specializationFunctionOwners[currentFunc] = snapshot.owners[functionName]
                end
            end
        end

        for functionName, currentFunc in pairs(snapshot.classObject) do
            if type(functionName) == "string"
                and type(currentFunc) == "function"
                and snapshot.functions[functionName] == nil then
                snapshot.functions[functionName] = currentFunc
                local currentOwner = self:getFunctionOwner(currentFunc)
                snapshot.owners[functionName] = isMod(currentOwner) and currentOwner or snapshot.owner
                if isMod(snapshot.owners[functionName]) then
                    self.specializationFunctionOwners[currentFunc] = snapshot.owners[functionName]
                end
            end
        end
    end
end

function HookAlert:auditEventListeners()
    for _, record in ipairs(self.eventListenerOrder) do
        local found = self:hasEventListener(record.objectType, record.eventName, record.spec)

        if not found then
            record.missingScans = (record.missingScans or 0) + 1
            local remover = record.removedBy or OWNER_UNKNOWN_REMOVER
            if record.missingScans >= 2 and remover ~= record.owner then
                self:raiseIssue("OVERWRITE", record.path, remover, record.owner, nil)
            end
        else
            record.removedBy = nil
            record.missingScans = 0
        end
    end
end


function HookAlert:observeHelper(container, key, factory)
    if type(container) ~= "table" or type(container[key]) ~= "function" then
        return false
    end

    local original = container[key]
    local wrapper = factory(original)
    self.observedHelpers[key] = {
        container = container,
        key = key,
        original = original,
        wrapper = wrapper
    }
    container[key] = wrapper
    return true
end

function HookAlert:installHelperObservation()
    local observer = self
    local observedCount = 0

    if type(Utils) == "table" then
        self:observeHelper(Utils, "getFilename", function(original)
            return function(filename, baseDirectory, ...)
                observer:observeModDirectory(baseDirectory)
                return original(filename, baseDirectory, ...)
            end
        end)

        local helperKinds = {
            appendedFunction = "APPEND",
            prependedFunction = "PREPEND",
            overwrittenFunction = "OVERWRITE"
        }
        for key, kind in pairs(helperKinds) do
            local observedKind = kind
            if self:observeHelper(Utils, key, function(original)
                return function(previousFunc, hookFunc, ...)
                    local owner = observer:getObservedOwner(hookFunc)
                    -- Observe construction metadata only. Passing the exact hook
                    -- object through is the compatibility boundary: Script Sentry
                    -- must never become part of the resulting gameplay chain.
                    local wrappedFunc = original(previousFunc, hookFunc, ...)
                    observer:recordWrapper(observedKind, wrappedFunc, previousFunc, hookFunc, owner)
                    return wrappedFunc
                end
            end) then
                observedCount = observedCount + 1
            end
        end
    end

    if type(SpecializationUtil) == "table" then
        for _, key in ipairs({"registerFunction", "registerOverwrittenFunction"}) do
            local observedKey = key
            self:observeHelper(SpecializationUtil, observedKey, function(original)
                return function(objectType, functionName, hookFunc, ...)
                    local beforeFunc = type(objectType) == "table"
                        and type(objectType.functions) == "table"
                        and objectType.functions[functionName]
                        or nil
                    local owner = observer:getObservedOwner(hookFunc)
                    local results = packValues(original(objectType, functionName, hookFunc, ...))
                    local afterFunc = type(objectType) == "table"
                        and type(objectType.functions) == "table"
                        and objectType.functions[functionName]
                        or nil
                    observer:recordTypeFunctionRegistration(
                        objectType,
                        functionName,
                        hookFunc,
                        beforeFunc,
                        afterFunc,
                        owner
                    )
                    return unpackValues(results, 1, results.n)
                end
            end)
        end

        self:observeHelper(SpecializationUtil, "registerEventListener", function(original)
            return function(objectType, eventName, spec, ...)
                local eventFunc = type(spec) == "table" and spec[eventName] or nil
                local owner = observer:getObservedOwner(eventFunc)
                local results = packValues(original(objectType, eventName, spec, ...))
                observer:recordEventListenerRegistration(objectType, eventName, spec, owner)
                return unpackValues(results, 1, results.n)
            end
        end)

        self:observeHelper(SpecializationUtil, "removeEventListener", function(original)
            return function(objectType, eventName, spec, ...)
                local wasRegistered = observer:hasEventListener(objectType, eventName, spec)
                local owner = observer:getObservedOwner(nil)
                local results = packValues(original(objectType, eventName, spec, ...))
                local isRegistered = observer:hasEventListener(objectType, eventName, spec)
                observer:recordEventListenerRemoval(
                    objectType,
                    eventName,
                    spec,
                    owner,
                    wasRegistered,
                    isRegistered
                )
                return unpackValues(results, 1, results.n)
            end
        end)
    end

    if type(SpecializationManager) == "table" then
        self:observeHelper(SpecializationManager, "addSpecialization", function(original)
            return function(manager, name, className, filename, customEnvironment, ...)
                local owner = observer:getModNameFromPath(filename)
                local results = packValues(original(
                    manager,
                    name,
                    className,
                    filename,
                    customEnvironment,
                    ...
                ))
                local classObject = nil
                if type(manager) == "table"
                    and type(manager.getSpecializationObjectByName) == "function" then
                    local ok, value = pcall(manager.getSpecializationObjectByName, manager, name)
                    if ok then
                        classObject = value
                    end
                end
                if classObject == nil
                    and type(ClassUtil) == "table"
                    and type(ClassUtil.getClassObject) == "function" then
                    local ok, value = pcall(ClassUtil.getClassObject, className)
                    if ok then
                        classObject = value
                    end
                end
                if results[1] ~= false then
                    observer:captureSpecializationClass(name, className, filename, classObject, owner)
                end
                return unpackValues(results, 1, results.n)
            end
        end)
    end

    self.canObserveWrappers = observedCount > 0
end

function HookAlert:restoreHelperObservation()
    if self.helpersRestored then
        return
    end
    self.helpersRestored = true

    for _, helper in pairs(self.observedHelpers) do
        if helper.container[helper.key] == helper.wrapper then
            helper.container[helper.key] = helper.original
        else
            self:log("NOTICE: %s changed again after Script Sentry observed it; left untouched", helper.key)
        end
    end
end

function HookAlert:addRecordedParticipants(startFunc, participants)
    local cursor = startFunc
    local visited = {}
    local newestOwner = nil

    for _ = 1, 64 do
        if type(cursor) ~= "function" or visited[cursor] then
            break
        end
        visited[cursor] = true

        local record = self.wrapperRecords[cursor]
        if record == nil then
            break
        end

        local owner = record.owner
        if not isMod(owner) then
            owner = self:getFunctionOwner(record.hookFunc)
        end
        if isMod(owner) then
            participants[owner] = true
            newestOwner = newestOwner or owner
        end
        cursor = record.previousFunc
    end
    return newestOwner
end

function HookAlert:getLatestRecordedChainForRoot(rootFunc)
    for index = #self.wrapperOrder, 1, -1 do
        local record = self.wrapperOrder[index]
        if record.rootFunc == rootFunc then
            return record
        end
    end
    return nil
end

function HookAlert:analyzeRecordedTransition(newFunc, oldFunc, oldOwner)
    local participants = {}
    if isMod(oldOwner) then
        participants[oldOwner] = true
    end

    local cursor = newFunc
    local visited = {}
    local newestOwner = nil

    for _ = 1, 64 do
        if cursor == oldFunc then
            return true, participants, newestOwner or oldOwner, nil, nil
        end
        if type(cursor) ~= "function" or visited[cursor] then
            return false, participants, newestOwner, OWNER_UNKNOWN, nil
        end
        visited[cursor] = true

        local record = self.wrapperRecords[cursor]
        if record == nil then
            local cutOwner = self:getFunctionOwner(cursor)
            if isMod(cutOwner) then
                participants[cutOwner] = true
                newestOwner = newestOwner or cutOwner
            end

            local displacedOwner = nil
            local abandoned = self:getLatestRecordedChainForRoot(oldFunc)
            if abandoned ~= nil and abandoned.resultFunc ~= newFunc then
                displacedOwner = self:addRecordedParticipants(abandoned.resultFunc, participants)
            end
            return false, participants, newestOwner, cutOwner, displacedOwner
        end

        local owner = record.owner
        if not isMod(owner) then
            owner = self:getFunctionOwner(record.hookFunc)
        end
        if isMod(owner) then
            participants[owner] = true
            newestOwner = newestOwner or owner
        end
        cursor = record.previousFunc
    end

    return false, participants, newestOwner, OWNER_UNKNOWN, nil
end

function HookAlert:getFunctionUpvalues(func)
    local functions = {}
    if not self.canInspectClosures or type(func) ~= "function" then
        return functions
    end

    for index = 1, 64 do
        local ok, name, value = pcall(debug.getupvalue, func, index)
        if not ok or name == nil then
            break
        end
        if type(value) == "function" then
            table.insert(functions, {
                name = name,
                normalizedName = normalizeName(name),
                func = value
            })
        end
    end
    return functions
end

function HookAlert:functionGraphContains(startFunc, targetFunc, depth, visited)
    if startFunc == targetFunc then
        return true
    end
    if depth <= 0 or visited[startFunc] then
        return false
    end
    visited[startFunc] = true

    for _, upvalue in ipairs(self:getFunctionUpvalues(startFunc)) do
        if self:functionGraphContains(upvalue.func, targetFunc, depth - 1, visited) then
            return true
        end
    end
    return false
end

function HookAlert:choosePreviousFunction(upvalues, targetFunc)
    for _, upvalue in ipairs(upvalues) do
        if upvalue.func == targetFunc then
            return upvalue.func
        end
    end

    for _, upvalue in ipairs(upvalues) do
        if PREVIOUS_UPVALUE_NAMES[upvalue.normalizedName] then
            return upvalue.func
        end
    end

    -- Fallback for stripped or differently named wrappers: choose the upvalue
    -- whose closure graph demonstrably reaches the exact prior function.
    for _, upvalue in ipairs(upvalues) do
        if self:functionGraphContains(upvalue.func, targetFunc, 24, {}) then
            return upvalue.func
        end
    end
    return nil
end

function HookAlert:analyzeTransition(newFunc, oldFunc, oldOwner)
    if not self.canInspectClosures then
        return self:analyzeRecordedTransition(newFunc, oldFunc, oldOwner)
    end

    local participants = {}
    if isMod(oldOwner) then
        participants[oldOwner] = true
    end

    local cursor = newFunc
    local visited = {}
    local newestOwner = nil

    for _ = 1, 64 do
        if cursor == oldFunc then
            return true, participants, newestOwner or oldOwner, nil
        end
        if visited[cursor] then
            return false, participants, newestOwner, OWNER_UNKNOWN
        end
        visited[cursor] = true

        local cursorOwner = self:getFunctionOwner(cursor)
        if isMod(cursorOwner) then
            participants[cursorOwner] = true
            newestOwner = newestOwner or cursorOwner
        end

        local upvalues = self:getFunctionUpvalues(cursor)
        local previousFunc = self:choosePreviousFunction(upvalues, oldFunc)

        for _, upvalue in ipairs(upvalues) do
            if upvalue.func ~= previousFunc then
                local hookOwner = self:getFunctionOwner(upvalue.func)
                if isMod(hookOwner) and (HOOK_UPVALUE_NAMES[upvalue.normalizedName] or previousFunc ~= nil) then
                    participants[hookOwner] = true
                    newestOwner = newestOwner or hookOwner
                end
            end
        end

        if previousFunc == nil then
            local cutOwner = cursorOwner
            if not isMod(cutOwner) then
                for _, upvalue in ipairs(upvalues) do
                    local candidateOwner = self:getFunctionOwner(upvalue.func)
                    if isMod(candidateOwner) then
                        cutOwner = candidateOwner
                        break
                    end
                end
            end
            return false, participants, newestOwner, cutOwner
        end
        cursor = previousFunc
    end

    return false, participants, newestOwner, OWNER_UNKNOWN
end

function HookAlert:analyzeStandaloneChain(func)
    if not self.canInspectClosures then
        local participants = {}
        self:addRecordedParticipants(func, participants)
        return participants
    end

    local participants = {}
    local cursor = func
    local visited = {}

    for _ = 1, 64 do
        if visited[cursor] then
            break
        end
        visited[cursor] = true

        local cursorOwner = self:getFunctionOwner(cursor)
        if isMod(cursorOwner) then
            participants[cursorOwner] = true
        end

        local upvalues = self:getFunctionUpvalues(cursor)
        local previousFunc = nil
        for _, upvalue in ipairs(upvalues) do
            if PREVIOUS_UPVALUE_NAMES[upvalue.normalizedName] then
                previousFunc = upvalue.func
                break
            end
        end
        if previousFunc == nil then
            break
        end

        for _, upvalue in ipairs(upvalues) do
            if upvalue.func ~= previousFunc then
                local hookOwner = self:getFunctionOwner(upvalue.func)
                if isMod(hookOwner) then
                    participants[hookOwner] = true
                end
            end
        end
        cursor = previousFunc
    end
    return participants
end

function HookAlert:addObjectFunctions(slots, label, object)
    if type(object) ~= "table" then
        return
    end

    local seenNames = {}
    local cursor = object
    for _ = 1, 8 do
        if type(cursor) ~= "table" then
            break
        end
        for name, value in pairs(cursor) do
            if type(name) == "string" and type(value) == "function" and not seenNames[name] then
                slots[label .. "." .. name] = value
                seenNames[name] = true
            end
        end
        local metatable = getmetatable(cursor)
        cursor = metatable ~= nil and metatable.__index or nil
    end
end

function HookAlert:addTrackedTypeFunctions(slots)
    for _, record in ipairs(self.typeFunctionOrder) do
        local functions = type(record.objectType) == "table" and record.objectType.functions or nil
        local func = type(functions) == "table" and functions[record.functionName] or nil
        if type(func) == "function" then
            slots[record.path] = func
        end
    end
end

function HookAlert:collectSlots()
    local slots = {}
    for globalName, value in pairs(_G) do
        if type(globalName) == "string" then
            if type(value) == "function" then
                slots[globalName] = value
            elseif type(value) == "table" and value ~= _G then
                self:addObjectFunctions(slots, globalName, value)
            end
        end
    end

    if g_currentMission ~= nil then
        self:addObjectFunctions(slots, "$mission", g_currentMission)
        self:addObjectFunctions(slots, "$mission.hud", g_currentMission.hud)
        self:addObjectFunctions(slots, "$mission.environment", g_currentMission.environment)
        self:addObjectFunctions(slots, "$mission.aiSystem", g_currentMission.aiSystem)
    end
    self:addTrackedTypeFunctions(slots)
    return slots
end

function HookAlert:isInfrastructurePath(path)
    if INFRASTRUCTURE_PATHS[path] then
        return true
    end
    return string.match(tostring(path), "^g_[%w_]*SpecializationManager%.addSpecialization$") ~= nil
end

function HookAlert:getIssueKeyPath(path)
    local normalized = tostring(path or "unknown")
    normalized = string.gsub(
        normalized,
        "^%$objectType%b[]%.functions%.",
        "$objectType.functions."
    )
    normalized = string.gsub(
        normalized,
        "^%$objectType%b[]%.eventListeners%.",
        "$objectType.eventListeners."
    )
    return normalized
end

function HookAlert:scanSlots()
    local current = self:collectSlots()

    for path, oldFunc in pairs(self.snapshot) do
        local newFunc = current[path]
        if newFunc == nil then
            if not self:isInfrastructurePath(path) then
                local oldOwner = self.ownerBySlot[path] or self:getFunctionOwner(oldFunc)
                self:raiseIssue("OVERWRITE", path, OWNER_UNKNOWN_REMOVER, oldOwner, nil)
            end
            self.ownerBySlot[path] = nil
            self.participantsBySlot[path] = nil
        elseif newFunc ~= oldFunc then
            self:inspectTransition(path, oldFunc, newFunc)
        end
    end

    for path, newFunc in pairs(current) do
        if self.snapshot[path] == nil then
            local participants = self:analyzeStandaloneChain(newFunc)
            local newOwner = self:getFunctionOwner(newFunc)
            self.ownerBySlot[path] = newOwner
            self.participantsBySlot[path] = participants
            if count(participants) >= 2 and not self:isInfrastructurePath(path) then
                self:raiseIssue("OVERLAP", path, newOwner, OWNER_UNKNOWN, participants)
            end
        end
    end
    self.snapshot = current
end

function HookAlert:inspectTransition(path, oldFunc, newFunc)
    if self:isInfrastructurePath(path) then
        return
    end

    local oldOwner = self.ownerBySlot[path] or self:getFunctionOwner(oldFunc)
    if not self.canInspectClosures and not self.canObserveWrappers then
        self.ownerBySlot[path] = self:getFunctionOwner(newFunc)
        return
    end

    local preserved, participants, newestOwner, cutOwner, displacedOwner = self:analyzeTransition(newFunc, oldFunc, oldOwner)
    local priorParticipants = self.participantsBySlot[path] or {}
    for owner in pairs(priorParticipants) do
        participants[owner] = true
    end

    if preserved then
        self.ownerBySlot[path] = newestOwner or oldOwner
        self.participantsBySlot[path] = participants
        if count(participants) >= 2 then
            self:raiseIssue("OVERLAP", path, newestOwner, oldOwner, participants)
        end
        return
    end

    local writer = cutOwner
    if self.canInspectClosures and not isMod(writer) then
        writer = newestOwner
    end
    if self.canInspectClosures and not isMod(writer) then
        writer = self:getFunctionOwner(newFunc)
    end
    writer = writer or OWNER_UNKNOWN

    self.ownerBySlot[path] = writer
    self.participantsBySlot[path] = isMod(writer) and {[writer] = true} or {}
    if isMod(writer) and writer ~= oldOwner then
        self:raiseIssue("OVERWRITE", path, writer, displacedOwner or oldOwner, nil)
    end
end

function HookAlert:raiseIssue(kind, path, writer, displaced, participants)
    writer = writer or OWNER_UNKNOWN
    displaced = displaced or OWNER_UNKNOWN
    local participantText = participants ~= nil and joinedNames(participants) or ""
    local issueKeyPath = self:getIssueKeyPath(path)
    local key
    if kind == "OVERLAP" then
        key = table.concat({kind, issueKeyPath, participantText}, "|")
    else
        key = table.concat({kind, issueKeyPath, writer, displaced}, "|")
    end

    local issue = self.issues[key]
    if issue ~= nil then
        return
    end

    issue = {
        key = key,
        kind = kind,
        path = path,
        writer = writer,
        displaced = displaced,
        participants = participants
    }
    self.issues[key] = issue
    table.insert(self.issueOrder, issue)

    if kind == "OVERWRITE" then
        self:log("OVERWRITE: %s replaced %s at %s", writer, displaced, path)
    else
        self:log("OVERLAP (chain intact): %s at %s", participantText, path)
    end

    if self.summarySent then
        self:buildReview(false)
    end
end

function HookAlert:raiseUiIssue(detection)
    local key = "GUI_INTEGRITY|" .. tostring(detection.key or "unknown")
    local issue = self.issues[key]
    local isNew = issue == nil
    local issueKind = detection.severity == "RED" and "UI_CORRUPTION" or "UI_WARNING"
    local affectedText = detection.affectedText or table.concat(detection.affected or {}, ", ")
    local playerAffectedText = detection.playerAffectedText
        or table.concat(detection.playerAffected or {}, ", ")
    local evidenceText = detection.evidenceText or table.concat(detection.evidence or {}, "; ")
    local signature = table.concat({
        issueKind,
        tostring(detection.writer or ""),
        tostring(detection.screen or ""),
        tostring(detection.problem or ""),
        affectedText,
        playerAffectedText,
        evidenceText
    }, "|")
    local changed = issue == nil or issue.signature ~= signature

    if issue == nil then
        issue = {
            key = key,
            kind = issueKind
        }
        self.issues[key] = issue
        table.insert(self.issueOrder, issue)
    end

    issue.kind = issueKind
    issue.signature = signature
    issue.category = detection.category
    issue.writer = detection.writer or "unattributed GUI modifier"
    issue.screen = detection.screen or "GUI"
    issue.problem = detection.problem or "contains suspicious GUI data"
    issue.affectedText = affectedText
    issue.playerAffectedText = playerAffectedText ~= "" and playerAffectedText or "menu controls"
    issue.evidenceText = evidenceText

    if changed then
        self:log(
            "%s: %s %s on %s; affected=%s; evidence=%s",
            issue.kind == "UI_CORRUPTION" and "GUI CORRUPTION" or "GUI RISK",
            issue.writer,
            issue.problem,
            issue.screen,
            issue.affectedText,
            issue.evidenceText
        )
    end

    if self.summarySent and changed then
        self:buildReview(false)
        if isNew and issue.kind == "UI_CORRUPTION" then
            -- A late GUI finding is usually discovered while the player is
            -- using the affected menu. Opening an InfoDialog at that moment
            -- is blocked by FS25, so openReview used to queue it and display
            -- it as soon as the player closed the menu. Keep monitoring and
            -- refresh the stored review, but leave opening it to RIGHT ALT+1.
            self:log("New confirmed GUI problem saved - press RIGHT ALT + 1 to view the updated review")
        end
    end
end

function HookAlert:getReviewItem(issue)
    if issue.kind == "OVERWRITE" then
        local knownWriter = isMod(issue.writer)
        local affectsFollowMe = string.find(
            string.lower(tostring(issue.displaced or "") .. " " .. tostring(issue.path or "")),
            "followme",
            1,
            true
        ) ~= nil
        local normalizedPath = string.lower(tostring(issue.path or ""))
        local affectsFollowMeSelection = affectsFollowMe
            and (string.find(normalizedPath, "ondraw", 1, true) ~= nil
                or string.find(normalizedPath, "drawnearbyvehicles", 1, true) ~= nil
                or string.find(normalizedPath, "findvehiclesnearby", 1, true) ~= nil
                or string.find(normalizedPath, "actioneventinitiate", 1, true) ~= nil
                or string.find(normalizedPath, "onupdatetick", 1, true) ~= nil)
        return {
            kind = "OVERWRITE",
            primary = "Mod: " .. (knownWriter and issue.writer or "could not be identified"),
            secondary = affectsFollowMeSelection
                and "Problem: stopped Follow Me's vehicle-selection line from appearing"
                or ("Problem: replaced " .. issue.displaced .. " code without continuing it"),
            evidence = affectsFollowMeSelection
                and "Affects: choosing a lead vehicle with Follow Me"
                or affectsFollowMe
                and "Affects: Follow Me controls and vehicle AI"
                or "Affects: a shared game function used by both mods",
            advice = knownWriter
                and ("What to do: update or disable " .. issue.writer .. ", then reload the save.")
                or "What to do: send log.txt; Script Sentry saw the removal but could not name the mod."
        }
    end
    if issue.kind == "UI_CORRUPTION" then
        local knownWriter = issue.writer ~= "unattributed GUI modifier"
        return {
            kind = issue.kind,
            primary = "Mod: " .. (knownWriter and issue.writer or "could not be identified"),
            secondary = "Problem: " .. issue.problem,
            evidence = "Affects: " .. issue.screen .. " - " .. issue.playerAffectedText,
            advice = knownWriter
                and ("What to do: update or disable " .. issue.writer .. ", then reload the save.")
                or "What to do: reload once. If it repeats, send log.txt to the mod author."
        }
    end
    return nil
end

function HookAlert:buildReview(openNow)
    local overwriteCount = 0
    local uiCorruptionCount = 0
    local uiWarningCount = 0
    local overlapCount = 0
    for _, issue in ipairs(self.issueOrder) do
        if issue.kind == "OVERWRITE" then
            overwriteCount = overwriteCount + 1
        elseif issue.kind == "UI_CORRUPTION" then
            uiCorruptionCount = uiCorruptionCount + 1
        elseif issue.kind == "UI_WARNING" then
            uiWarningCount = uiWarningCount + 1
        elseif issue.kind == "OVERLAP" then
            overlapCount = overlapCount + 1
        end
    end

    local confirmedItems = {}
    for _, issue in ipairs(self.issueOrder) do
        if issue.kind == "UI_CORRUPTION" then
            table.insert(confirmedItems, self:getReviewItem(issue))
        end
    end
    for _, issue in ipairs(self.issueOrder) do
        if issue.kind == "OVERWRITE" then
            table.insert(confirmedItems, self:getReviewItem(issue))
        end
    end

    local confirmedCount = #confirmedItems
    local items = {}
    for index = 1, math.min(confirmedCount, MAX_PLAYER_ITEMS) do
        table.insert(items, confirmedItems[index])
    end

    local reviewKind
    local reviewTitle
    local summary
    local detail = "No files, mods, savegames, or keybindings were changed."
    local limited = not self.canInspectClosures
        and (not self.canObserveWrappers or not self.ownerAttributionObserved)
        and confirmedCount == 0

    if confirmedCount > 0 then
        reviewKind = "OVERWRITE"
        reviewTitle = confirmedCount == 1
            and "SCRIPT SENTRY 0.5.4.0 - PROBLEM FOUND"
            or "SCRIPT SENTRY 0.5.4.0 - PROBLEMS FOUND"
        summary = confirmedCount == 1
            and "1 confirmed problem was found."
            or string.format("%d confirmed problems were found.", confirmedCount)
        if confirmedCount > MAX_PLAYER_ITEMS then
            detail = string.format(
                "The first %d are shown. All confirmed details are in log.txt.",
                MAX_PLAYER_ITEMS
            )
        else
            detail = "Only confirmed problems are shown. Technical notes remain in log.txt."
        end
    elseif limited then
        reviewKind = "INFO"
        reviewTitle = "SCRIPT SENTRY 0.5.4.0 - CHECK COMPLETE"
        summary = "No confirmed problem was found."
        detail = "Some mod ownership could not be verified. Technical notes are in log.txt."
    else
        reviewKind = "SAFE"
        reviewTitle = "SCRIPT SENTRY 0.5.4.0 - CHECK COMPLETE"
        summary = "No confirmed problem was found."
        detail = "No action is needed. Compatible shared scripts are not treated as conflicts."
    end

    self.hud:setReview(reviewKind, reviewTitle, summary, detail, items)
    self:log(
        "Startup review ready: guiCorruptions=%d guiRisks=%d overwrites=%d intactOverlaps=%d pages=%d",
        uiCorruptionCount,
        uiWarningCount,
        overwriteCount,
        overlapCount,
        self.hud:getPageCount()
    )
    if openNow then
        self.hud:openReview(true, true)
    end
end

function HookAlert:queueSummary()
    self:buildReview(true)
end

function HookAlert:areActionEventsAlive()
    if not self.actionEventsRegistered
        or self.actionEventId == nil
        or self.performanceActionEventId == nil then
        return false
    end
    if g_inputBinding == nil or g_inputBinding.events == nil then
        return true
    end
    return g_inputBinding.events[self.actionEventId] ~= nil
        and g_inputBinding.events[self.performanceActionEventId] ~= nil
end

function HookAlert:removeActionEvents()
    if self.actionEventId ~= nil
        and g_inputBinding ~= nil
        and type(g_inputBinding.removeActionEvent) == "function" then
        g_inputBinding:removeActionEvent(self.actionEventId)
    end
    if self.performanceActionEventId ~= nil
        and g_inputBinding ~= nil
        and type(g_inputBinding.removeActionEvent) == "function" then
        g_inputBinding:removeActionEvent(self.performanceActionEventId)
    end
    self.actionEventId = nil
    self.performanceActionEventId = nil
    self.actionEventsRegistered = false
end

function HookAlert:registerActionEvents()
    if self:areActionEventsAlive() then
        return true
    end
    if self.actionEventsRegistered then
        self:removeActionEvents()
    end
    -- registerActionEvent attaches to whichever input context is current. If a
    -- startup menu is visible, that context is temporary and the shortcut dies
    -- when the menu closes. Wait for the normal gameplay context instead.
    if g_gui ~= nil and type(g_gui.getIsGuiVisible) == "function" then
        local ok, isVisible = pcall(g_gui.getIsGuiVisible, g_gui)
        if ok and isVisible then
            return false
        end
    end
    if g_inputBinding == nil
        or type(g_inputBinding.registerActionEvent) ~= "function"
        or type(InputAction) ~= "table"
        or InputAction.SCRIPT_SENTRY_REVIEW == nil
        or InputAction.SCRIPT_SENTRY_PERFORMANCE == nil then
        return false
    end

    local _, eventId = g_inputBinding:registerActionEvent(
        InputAction.SCRIPT_SENTRY_REVIEW,
        self,
        HookAlert.onActionCall,
        false,
        true,
        false,
        true
    )
    if eventId == nil then
        return false
    end

    local _, performanceEventId = g_inputBinding:registerActionEvent(
        InputAction.SCRIPT_SENTRY_PERFORMANCE,
        self,
        HookAlert.onActionCall,
        false,
        true,
        false,
        true
    )
    if performanceEventId == nil then
        if type(g_inputBinding.removeActionEvent) == "function" then
            g_inputBinding:removeActionEvent(eventId)
        end
        return false
    end

    self.actionEventId = eventId
    self.performanceActionEventId = performanceEventId
    self.actionEventsRegistered = true
    if type(g_inputBinding.setActionEventTextVisibility) == "function" then
        -- Both actions remain available without adding permanent F1 help-HUD lines.
        g_inputBinding:setActionEventTextVisibility(eventId, false)
        g_inputBinding:setActionEventTextVisibility(performanceEventId, false)
    end
    if type(g_inputBinding.setActionEventTextPriority) == "function" and GS_PRIO_LOW ~= nil then
        g_inputBinding:setActionEventTextPriority(eventId, GS_PRIO_LOW)
        g_inputBinding:setActionEventTextPriority(performanceEventId, GS_PRIO_LOW)
    end
    self:log("Actions registered - RIGHT ALT + 1 opens startup review; RIGHT ALT + 2 runs a safe 15-second FPS check")
    return true
end

function HookAlert:onActionCall(actionName, inputValue, callbackState, isAnalog)
    if inputValue ~= nil and inputValue <= 0 then
        return
    end
    if type(InputAction) == "table" and actionName == InputAction.SCRIPT_SENTRY_REVIEW then
        self:log("Review shortcut received")
        local opened = self.hud:openReview(false, false)
        if opened then
            self:log("Review shortcut opened the dialog")
        elseif self.hud.pendingOpen then
            self:log("Review shortcut queued the dialog until the current menu closes")
        else
            self:log("Review shortcut could not open the dialog")
        end
    elseif type(InputAction) == "table"
        and actionName == InputAction.SCRIPT_SENTRY_PERFORMANCE
        and self.performance ~= nil then
        self:log("Safe FPS check shortcut received")
        self.performance:handleAction()
    end
end

function HookAlert:loadMap(mapName)
    self.runtimeMs = 0
    self.scanAccumulator = 0
    self.uiScanAccumulator = 0
    self.summarySent = false
    self.missionReady = false
    self.hud:reset()
    self.hud:setReview(
        "INFO",
        "SCRIPT SENTRY - SCAN IN PROGRESS",
        "The startup review is being prepared.",
        "It will open automatically when the scan finishes.",
        {}
    )
    self.performance:loadMap()
    self.uiIntegrity:resetSession()
    self:scanSlots()
end

function HookAlert:update(dt)
    if not self.missionReady then
        if g_currentMission == nil or g_currentMission.isMissionStarted == true then
            self.missionReady = true
            self.runtimeMs = 0
            self.scanAccumulator = 0
            self.uiScanAccumulator = 0
            if g_currentMission ~= nil then
                self.performance:onMissionReady()
            end
        else
            self.hud:update(dt)
            self.performance:update(dt)
            return
        end
    end

    self:registerActionEvents()

    self.runtimeMs = self.runtimeMs + dt
    self.scanAccumulator = self.scanAccumulator + dt
    self.uiScanAccumulator = self.uiScanAccumulator + dt

    -- Continue checking after the startup review. Several settings mods build
    -- or refresh their controls only when the menu is opened for the first time.
    if self.uiScanAccumulator >= self.uiScanInterval then
        self.uiScanAccumulator = 0
        self.uiIntegrity:scan()
    end

    local activeScanInterval = self.summarySent and self.runtimeScanInterval or self.scanInterval
    if self.scanAccumulator >= activeScanInterval then
        self.scanAccumulator = 0
        self:scanSlots()
        self:auditSpecializationClasses()
        self:auditEventListeners()
    end

    if not self.summarySent and self.runtimeMs >= self.summaryDelay then
        self:restoreHelperObservation()
        self:scanSlots()
        self:auditSpecializationClasses()
        self:auditEventListeners()
        self.uiIntegrity:scan()
        self:log(
            "Specialization audit coverage: classes=%d typeFunctions=%d eventListeners=%d",
            #self.specializationSnapshotOrder,
            #self.typeFunctionOrder,
            #self.eventListenerOrder
        )
        self.summarySent = true
        self:queueSummary()
    end
    self.hud:update(dt)
    self.performance:update(dt)
end

function HookAlert:draw()
    self.hud:draw()
end

function HookAlert:deleteMap()
    self:restoreHelperObservation()
    self:removeActionEvents()
    self.hud:reset()
    self.performance:deleteMap()
end

function HookAlert:delete()
    self:restoreHelperObservation()
    self:removeActionEvents()
    self.hud:reset()
    self.performance:delete()
    self.uiIntegrity:delete()
end
