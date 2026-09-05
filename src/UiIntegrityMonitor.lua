--
-- Script Sentry general GUI integrity monitor.
--
-- This observer protects the GUI structure which already exists when Script
-- Sentry loads, tracks ownership of later mod-added controls, and validates
-- every discoverable GUI screen for concrete data/structure faults. It is
-- deliberately read-only: observed methods are forwarded unchanged and no
-- control is repaired, removed, hidden, or rebound.
--

UiIntegrityMonitor = {}
local UiIntegrityMonitor_mt = Class(UiIntegrityMonitor)

local OWNER_GIANTS = "GIANTS base game"
local OWNER_UNKNOWN = "unattributed GUI modifier"
local MAX_TREE_DEPTH = 48
local MAX_TREE_ELEMENTS = 6000
local MIN_WHOLE_SCREEN_SIZE = 8
local REPORT_AFTER_SCANS = 2
local MIN_LAYOUT_REPLACEMENT_ELEMENTS = 12
local MIN_LAYOUT_REPLACEMENT_RATIO = 0.35

local CALLBACK_FIELDS = {
    "onClick",
    "onCreate",
    "onOpen",
    "onClose",
    "onChange",
    "onEnter",
    "onLeave",
    "onFocus",
    "onFocusLeave",
    "onDoubleClick",
    "onEscPressed",
    "onTextChanged",
    "onIsChecked"
}

local GEOMETRY_FIELDS = {
    "position",
    "size",
    "absPosition",
    "absSize"
}

local PLAYER_CONTROL_NAMES = {
    checkUseMiles = "Measuring Unit",
    checkUseFahrenheit = "Temperature Unit",
    checkUseAcre = "Area Unit"
}

local ROUTED_METHODS = {
    addElement = "ADD_ELEMENT",
    clone = "CLONE",
    exposeControlsAsFields = "EXPOSE_FIELDS",
    onGuiSetupFinished = "SETUP_FINISHED",
    removeElement = "REMOVE_ELEMENT",
    setId = "SET_ID",
    setState = "SET_STATE",
    setTexts = "SET_TEXTS",
    unlinkElement = "REMOVE_ELEMENT"
}

local CATEGORY_PROBLEMS = {
    CALLBACK = "created a menu control whose action cannot run",
    DUPLICATE_ID = "created duplicate control names",
    GEOMETRY = "gave a menu control an invalid position or size",
    LOCALIZATION = "left untranslated menu text visible",
    OPTION_CORRUPTION = "replaced normal menu choices with OFF / ON or YES / NO",
    OPTION_STATE = "left a menu choice in an invalid state",
    PARENT_LINK = "damaged a menu layout connection",
    STRUCTURE = "removed a menu control that is still in use",
    WHOLE_SCREEN_SETUP = "reran setup on an existing menu"
}

local function trimLower(value)
    value = string.lower(tostring(value or ""))
    return string.gsub(value, "^%s*(.-)%s*$", "%1")
end

local function copyArray(values)
    if type(values) ~= "table" then
        return nil
    end
    local result = {}
    for index, value in ipairs(values) do
        result[index] = tostring(value or "")
    end
    return result
end

local function sameArray(first, second)
    if first == nil and second == nil then
        return true
    end
    if type(first) ~= "table" or type(second) ~= "table" or #first ~= #second then
        return false
    end
    for index = 1, #first do
        if first[index] ~= second[index] then
            return false
        end
    end
    return true
end

local function arraySignature(values)
    if type(values) ~= "table" then
        return "<missing>"
    end
    if #values == 0 then
        return "<empty>"
    end
    return table.concat(values, " | ")
end

local function appendUnique(values, seen, value, maximum)
    value = tostring(value or "")
    if value == "" or seen[value] or #values >= maximum then
        return
    end
    seen[value] = true
    table.insert(values, value)
end

local function isFiniteNumber(value)
    return type(value) ~= "number"
        or (value == value and value ~= math.huge and value ~= -math.huge)
end

local function humanize(value)
    value = tostring(value or "GUI")
    value = string.gsub(value, "^page", "")
    value = string.gsub(value, "([a-z0-9])([A-Z])", "%1 %2")
    value = string.gsub(value, "[_%-]+", " ")
    value = string.gsub(value, "^%s*(.-)%s*$", "%1")
    if value == "" then
        return "GUI"
    end
    return string.upper(string.sub(value, 1, 1)) .. string.sub(value, 2)
end

local function isElement(value)
    return type(value) == "table" and type(value.elements) == "table"
end

local function hasUnresolvedToken(value)
    if type(value) ~= "string" then
        return false
    end
    local normalized = string.lower(value)
    return string.find(normalized, "$l10n_", 1, true) ~= nil
        or string.find(normalized, "$ui_", 1, true) ~= nil
        or string.find(normalized, "missing l10n", 1, true) ~= nil
end

local function callbackValueIsEmpty(value)
    return value == nil
        or value == ""
        or value == "NO_CALLBACK"
        or value == "noCallback"
end

-- Tail-position forwarding preserves every return value from an observed GUI
-- method. An error from the original method still propagates normally.
local function finishObservedCall(observer, context, ...)
    observer:afterRoute(context, select(1, ...))
    return ...
end

function UiIntegrityMonitor.new(host, modName, customMt)
    local self = setmetatable({}, customMt or UiIntegrityMonitor_mt)
    self.host = host
    self.modName = modName
    self.installed = false
    self.installing = false
    self.routes = {}
    self.routeKeys = setmetatable({}, {__mode = "k"})
    self.originalByWrapper = setmetatable({}, {__mode = "k"})
    self.roots = {}
    self.rootsByObject = setmetatable({}, {__mode = "k"})
    self.rootForElement = setmetatable({}, {__mode = "k"})
    self.baselineByElement = setmetatable({}, {__mode = "k"})
    self.ownerByElement = setmetatable({}, {__mode = "k"})
    self.lastMutationByElement = setmetatable({}, {__mode = "k"})
    self.setupEvents = {}
    self.candidateCounts = {}
    self.publishedSignatures = {}
    self.sequence = 0
    self.setupDepth = 0
    self.scanNumber = 0
    return self
end

function UiIntegrityMonitor:log(message, ...)
    if select("#", ...) > 0 then
        message = string.format(message, ...)
    end
    print("[ScriptSentry GUI] " .. message)
end

function UiIntegrityMonitor:isUsableOwner(owner)
    return type(owner) == "string"
        and owner ~= ""
        and owner ~= self.modName
        and owner ~= OWNER_GIANTS
        and owner ~= "engine/C++"
        and owner ~= "unknown provider"
        and owner ~= OWNER_UNKNOWN
end

function UiIntegrityMonitor:getCallingOwner()
    if type(getfenv) == "function" then
        for level = 3, 24 do
            local ok, environment = pcall(getfenv, level)
            if not ok then
                break
            end
            if type(environment) == "table" then
                local owner = rawget(environment, "g_currentModName")
                if self:isUsableOwner(owner) then
                    return owner
                end
                local directory = rawget(environment, "g_currentModDirectory")
                if self.host ~= nil and type(self.host.getModNameFromPath) == "function" then
                    owner = self.host:getModNameFromPath(directory)
                    if self:isUsableOwner(owner) then
                        return owner
                    end
                end
            end
        end
    end

    if debug ~= nil and type(debug.getinfo) == "function" and self.host ~= nil then
        for level = 3, 24 do
            local ok, info = pcall(debug.getinfo, level, "S")
            if not ok or info == nil then
                break
            end
            local sourceName = string.gsub(tostring(info.source or info.short_src or ""), "^@", "")
            local owner = self.host:getModNameFromPath(sourceName)
            if self:isUsableOwner(owner) then
                return owner
            end
        end
    end

    if self.host ~= nil and type(self.host.getUiMutationOwner) == "function" then
        local owner = self.host:getUiMutationOwner()
        if self:isUsableOwner(owner) then
            return owner
        end
    end
    return OWNER_UNKNOWN
end

function UiIntegrityMonitor:getLocalizedText(key, fallback)
    if type(g_i18n) == "table" and type(g_i18n.getText) == "function" then
        local ok, value = pcall(g_i18n.getText, g_i18n, key)
        if ok and type(value) == "string" and value ~= "" and value ~= key then
            return value
        end
    end
    return fallback
end

function UiIntegrityMonitor:getBooleanPairName(texts)
    if type(texts) ~= "table" or #texts ~= 2 then
        return nil
    end
    local first = trimLower(texts[1])
    local second = trimLower(texts[2])
    local pairsToCheck = {
        {
            self:getLocalizedText("ui_off", "off"),
            self:getLocalizedText("ui_on", "on"),
            "OFF / ON"
        },
        {
            self:getLocalizedText("ui_no", "no"),
            self:getLocalizedText("ui_yes", "yes"),
            "NO / YES"
        }
    }
    for _, values in ipairs(pairsToCheck) do
        local pairFirst = trimLower(values[1])
        local pairSecond = trimLower(values[2])
        if (first == pairFirst and second == pairSecond)
            or (first == pairSecond and second == pairFirst) then
            return values[3]
        end
    end
    return nil
end

function UiIntegrityMonitor:getElementLabel(element)
    if type(element) ~= "table" then
        return "missing control"
    end
    for _, key in ipairs({"id", "name", "typeName", "profile"}) do
        local value = rawget(element, key)
        if type(value) == "string" and value ~= "" then
            return value
        end
    end
    return "unnamed GUI element"
end

function UiIntegrityMonitor:getPlayerElementLabel(element)
    local label = self:getElementLabel(element)
    if PLAYER_CONTROL_NAMES[label] ~= nil then
        return PLAYER_CONTROL_NAMES[label]
    end
    label = string.gsub(label, "^checkUse", "Use")
    label = string.gsub(label, "^check", "")
    return humanize(label)
end

function UiIntegrityMonitor:getRootInfo(element)
    if type(element) ~= "table" then
        return nil
    end
    local baseline = self.baselineByElement[element]
    if baseline ~= nil then
        return baseline.rootInfo
    end
    local known = self.rootForElement[element]
    if known ~= nil then
        return known
    end
    local cursor = element
    local visited = {}
    for _ = 1, MAX_TREE_DEPTH do
        if type(cursor) ~= "table" or visited[cursor] then
            break
        end
        visited[cursor] = true
        known = self.rootsByObject[cursor]
        if known ~= nil then
            return known
        end
        cursor = rawget(cursor, "parent")
    end
    return nil
end

function UiIntegrityMonitor:getElementPath(element, rootInfo)
    local parts = {}
    local cursor = element
    local visited = {}
    for _ = 1, 6 do
        if type(cursor) ~= "table" or visited[cursor] then
            break
        end
        visited[cursor] = true
        table.insert(parts, 1, self:getElementLabel(cursor))
        if rootInfo ~= nil and cursor == rootInfo.root then
            break
        end
        cursor = rawget(cursor, "parent")
    end
    return table.concat(parts, " > ")
end

function UiIntegrityMonitor:walkTree(root, visitor)
    if type(root) ~= "table" then
        return 0
    end
    local visited = {}
    local count = 0
    local function walk(element, parent, depth)
        if type(element) ~= "table"
            or visited[element]
            or depth > MAX_TREE_DEPTH
            or count >= MAX_TREE_ELEMENTS then
            return
        end
        visited[element] = true
        count = count + 1
        visitor(element, parent, depth)
        local children = rawget(element, "elements")
        if type(children) == "table" then
            for _, child in ipairs(children) do
                walk(child, element, depth + 1)
            end
        end
    end
    walk(root, nil, 0)
    return count
end

function UiIntegrityMonitor:captureTreeSet(root)
    local result = setmetatable({}, {__mode = "k"})
    self:walkTree(root, function(element)
        result[element] = true
    end)
    return result
end

function UiIntegrityMonitor:assignOwnerTree(root, owner, onlyUnowned)
    if not self:isUsableOwner(owner) then
        return
    end
    self:walkTree(root, function(element)
        if not onlyUnowned or self.ownerByElement[element] == nil then
            self.ownerByElement[element] = owner
        end
    end)
end

function UiIntegrityMonitor:captureCallbacks(element)
    local result = {}
    for _, field in ipairs(CALLBACK_FIELDS) do
        local value = rawget(element, field)
        if value ~= nil then
            result[field] = value
        end
    end
    return result
end

function UiIntegrityMonitor:captureBaselineElement(element, rootInfo)
    local snapshot = {
        rootInfo = rootInfo,
        id = rawget(element, "id"),
        name = rawget(element, "name"),
        parent = rawget(element, "parent"),
        target = rawget(element, "target"),
        profile = rawget(element, "profile"),
        texts = copyArray(rawget(element, "texts")),
        callbacks = self:captureCallbacks(element),
        callbackValidity = {},
        fieldBindings = {},
        mapBindings = {}
    }
    for field, callback in pairs(snapshot.callbacks) do
        snapshot.callbackValidity[field] = self:isCallbackValid(element, callback)
    end
    self.baselineByElement[element] = snapshot
    rootInfo.baselineElements[element] = snapshot
    local owner = rootInfo.owner
    if owner == nil then
        owner = OWNER_GIANTS
    end
    if self.ownerByElement[element] == nil then
        self.ownerByElement[element] = owner
    end
    return snapshot
end

function UiIntegrityMonitor:captureRootBindings(rootInfo)
    local controllers = setmetatable({}, {__mode = "k"})
    for element, snapshot in pairs(rootInfo.baselineElements) do
        snapshot.fieldBindings = {}
        snapshot.mapBindings = {}
        local target = rawget(element, "target")
        if type(target) == "table" then
            controllers[target] = true
        end
        if element == rootInfo.root then
            controllers[element] = true
        end
    end

    for controller in pairs(controllers) do
        for key, value in pairs(controller) do
            local snapshot = self.baselineByElement[value]
            if snapshot ~= nil and snapshot.rootInfo == rootInfo and type(key) == "string" then
                table.insert(snapshot.fieldBindings, {controller = controller, key = key})
            elseif type(key) == "string" and type(value) == "table" then
                local normalizedKey = string.lower(key)
                local hasMappingName = string.find(normalizedKey, "mapping", 1, true) ~= nil
                local isMapping = normalizedKey == "optionmapping"
                    or (hasMappingName
                        and (string.find(normalizedKey, "setting", 1, true) ~= nil
                            or string.find(normalizedKey, "control", 1, true) ~= nil))
                if isMapping then
                    for mappedElement, mappedValue in pairs(value) do
                        snapshot = self.baselineByElement[mappedElement]
                        if snapshot ~= nil and snapshot.rootInfo == rootInfo then
                            table.insert(snapshot.mapBindings, {
                                mapping = value,
                                key = key,
                                value = mappedValue
                            })
                        end
                    end
                end
            end
        end
    end
end

function UiIntegrityMonitor:baselineRoot(rootInfo)
    if rootInfo.baselined then
        return
    end
    rootInfo.baselined = true
    rootInfo.baselineElements = setmetatable({}, {__mode = "k"})
    rootInfo.baselineSiblingIdCounts = setmetatable({}, {__mode = "k"})
    rootInfo.rootIdBucket = {}
    rootInfo.baselineCount = self:walkTree(rootInfo.root, function(element, parent)
        self.rootForElement[element] = rootInfo
        local snapshot = self.baselineByElement[element]
        if snapshot == nil then
            snapshot = self:captureBaselineElement(element, rootInfo)
        elseif snapshot.rootInfo == rootInfo then
            rootInfo.baselineElements[element] = snapshot
        end
        local id = rawget(element, "id")
        if type(id) == "string" and id ~= "" then
            local bucketKey = parent or rootInfo.rootIdBucket
            local counts = rootInfo.baselineSiblingIdCounts[bucketKey]
            if counts == nil then
                counts = {}
                rootInfo.baselineSiblingIdCounts[bucketKey] = counts
            end
            counts[id] = (counts[id] or 0) + 1
        end
    end)
    self:captureRootBindings(rootInfo)
    self:log("baseline captured: %s (%d elements)", rootInfo.label, rootInfo.baselineCount)
end

-- Some large UI mods intentionally retire a complete base-game layer and use
-- a replacement screen. Treating every exposed field from the retired layer as
-- a dangling live control creates a convincing but false red report. A
-- wholesale layout change becomes the new structural baseline; isolated
-- removals remain protected and are still checked below.
function UiIntegrityMonitor:refreshReplacedLayout(rootInfo, currentSet)
    local baselineCount = 0
    local missingCount = 0
    for element in pairs(rootInfo.baselineElements or {}) do
        baselineCount = baselineCount + 1
        if not currentSet[element] then
            missingCount = missingCount + 1
        end
    end

    if baselineCount == 0
        or missingCount < MIN_LAYOUT_REPLACEMENT_ELEMENTS
        or missingCount / baselineCount < MIN_LAYOUT_REPLACEMENT_RATIO then
        return false
    end

    for element, snapshot in pairs(rootInfo.baselineElements or {}) do
        if snapshot.rootInfo == rootInfo then
            self.baselineByElement[element] = nil
            self.rootForElement[element] = nil
        end
    end
    self:walkTree(rootInfo.root, function(element)
        local snapshot = self.baselineByElement[element]
        if snapshot ~= nil and snapshot.rootInfo == rootInfo then
            self.baselineByElement[element] = nil
        end
    end)

    rootInfo.baselined = false
    rootInfo.layoutRefreshes = (rootInfo.layoutRefreshes or 0) + 1
    self:baselineRoot(rootInfo)
    self:log(
        "normal layout replacement learned: %s retired %d of %d prior elements; %d elements now active",
        rootInfo.label,
        missingCount,
        baselineCount,
        rootInfo.baselineCount
    )
    return true
end

function UiIntegrityMonitor:addRoot(root, label, owner)
    if not isElement(root) then
        return nil
    end
    local existing = self.rootsByObject[root]
    if existing ~= nil then
        return existing
    end
    owner = owner or self:getCallingOwner()
    if not self:isUsableOwner(owner) then
        owner = self.installing and OWNER_GIANTS or owner
    end
    local rootInfo = {
        root = root,
        label = humanize(label or rawget(root, "name") or rawget(root, "id") or "GUI"),
        owner = owner or OWNER_UNKNOWN,
        baselined = false
    }
    self.rootsByObject[root] = rootInfo
    table.insert(self.roots, rootInfo)
    self:baselineRoot(rootInfo)
    self:installRoute(root, "exposeControlsAsFields", "EXPOSE_FIELDS", rootInfo.label .. ".exposeControlsAsFields")
    self:installRoute(root, "onGuiSetupFinished", "SETUP_FINISHED", rootInfo.label .. ".onGuiSetupFinished")
    return rootInfo
end

function UiIntegrityMonitor:discoverContainer(container, label, depth, visited)
    if type(container) ~= "table" or visited[container] or depth > 3 then
        return
    end
    visited[container] = true
    if isElement(container) then
        local root = container
        local parent = rawget(root, "parent")
        local parentVisited = {}
        while isElement(parent) and not parentVisited[parent] do
            parentVisited[parent] = true
            root = parent
            parent = rawget(root, "parent")
        end

        -- Pages discovered directly from g_inGameMenu are more useful roots
        -- than the larger menu shell which contains them. Do not add a second
        -- overlapping root around an already protected page.
        for _, rootInfo in ipairs(self.roots) do
            local cursor = rootInfo.root
            local ancestors = {}
            while type(cursor) == "table" and not ancestors[cursor] do
                if cursor == root then
                    return
                end
                ancestors[cursor] = true
                cursor = rawget(cursor, "parent")
            end
        end

        self:addRoot(root, label)
        return
    end
    for key, value in pairs(container) do
        if type(value) == "table" then
            self:discoverContainer(value, label .. " " .. tostring(key), depth + 1, visited)
        end
    end
end

function UiIntegrityMonitor:discoverRoots()
    local discoveredPages = 0
    if type(g_inGameMenu) == "table" then
        for key, value in pairs(g_inGameMenu) do
            if type(key) == "string"
                and string.sub(key, 1, 4) == "page"
                and isElement(value) then
                self:addRoot(value, key)
                discoveredPages = discoveredPages + 1
            end
        end
        if discoveredPages == 0 and isElement(g_inGameMenu) then
            self:addRoot(g_inGameMenu, rawget(g_inGameMenu, "name") or "In-Game Menu")
        end
    end

    if type(g_gui) == "table" then
        local visited = {}
        for _, key in ipairs({"guis", "dialogs", "screenControllers"}) do
            local container = rawget(g_gui, key)
            if type(container) == "table" then
                self:discoverContainer(container, humanize(key), 0, visited)
            end
        end
    end
end

function UiIntegrityMonitor:recordMutation(element, owner, operation, beforeText, afterText)
    if type(element) ~= "table" then
        return
    end
    self.sequence = self.sequence + 1
    self.lastMutationByElement[element] = {
        owner = owner,
        operation = operation,
        beforeText = beforeText,
        afterText = afterText,
        sequence = self.sequence
    }
end

function UiIntegrityMonitor:getMutationWriter(element)
    local mutation = type(element) == "table" and self.lastMutationByElement[element] or nil
    if mutation ~= nil and self:isUsableOwner(mutation.owner) then
        return mutation.owner, mutation
    end
    if self.host ~= nil and type(self.host.getUiMutationOwner) == "function" then
        local owner = self.host:getUiMutationOwner()
        if self:isUsableOwner(owner) then
            return owner, mutation
        end
    end
    local owner = type(element) == "table" and self.ownerByElement[element] or nil
    if self:isUsableOwner(owner) then
        return owner, mutation
    end
    return OWNER_UNKNOWN, mutation
end

function UiIntegrityMonitor:isExternalWriter(element, owner)
    if not self:isUsableOwner(owner) then
        return false
    end
    local elementOwner = self.ownerByElement[element]
    return not self:isUsableOwner(elementOwner) or elementOwner ~= owner
end

function UiIntegrityMonitor:beforeRoute(kind, subject, routeName, ...)
    local context = {
        kind = kind,
        subject = subject,
        routeName = routeName,
        owner = self:getCallingOwner(),
        arg1 = select(1, ...),
        arg2 = select(2, ...),
        arg3 = select(3, ...),
        arg4 = select(4, ...)
    }
    if kind == "SET_TEXTS" then
        context.beforeTexts = copyArray(type(subject) == "table" and rawget(subject, "texts") or nil)
    elseif kind == "SET_ID" then
        context.beforeId = type(subject) == "table" and rawget(subject, "id") or nil
    elseif kind == "SET_STATE" then
        context.beforeState = type(subject) == "table" and rawget(subject, "state") or nil
    elseif kind == "LOAD_GUI" then
        context.parent = context.arg3
        if isElement(context.parent) then
            context.beforeElements = self:captureTreeSet(context.parent)
        end
    elseif kind == "SETUP_FINISHED" then
        context.outerSetup = self.setupDepth == 0
        self.setupDepth = self.setupDepth + 1
    end
    return context
end

function UiIntegrityMonitor:recordWholeScreenSetup(context)
    local element = context.subject
    local baseline = self.baselineByElement[element]
    if baseline == nil
        or not context.outerSetup
        or not self:isExternalWriter(element, context.owner) then
        return
    end
    local elementCount = self:walkTree(element, function() end)
    if elementCount < MIN_WHOLE_SCREEN_SIZE then
        return
    end
    local rootInfo = baseline.rootInfo or self:getRootInfo(element)
    local screen = rootInfo ~= nil and rootInfo.label or "GUI"
    local key = table.concat({context.owner, screen, self:getElementPath(element, rootInfo)}, "|")
    if self.setupEvents[key] == nil then
        self.setupEvents[key] = {
            owner = context.owner,
            rootInfo = rootInfo,
            element = element,
            count = elementCount
        }
        self:log(
            "%s reinitialized existing GUI subtree %s (%d elements)",
            context.owner,
            self:getElementPath(element, rootInfo),
            elementCount
        )
    end
end

function UiIntegrityMonitor:afterRoute(context, firstResult)
    if context == nil then
        return
    end
    local kind = context.kind
    local owner = context.owner
    local subject = context.subject
    if kind == "SETUP_FINISHED" then
        self.setupDepth = math.max(0, self.setupDepth - 1)
        self:recordWholeScreenSetup(context)
    elseif kind == "SET_TEXTS" then
        local afterTexts = copyArray(type(subject) == "table" and rawget(subject, "texts") or nil)
        if not sameArray(context.beforeTexts, afterTexts) then
            self:recordMutation(subject, owner, context.routeName, arraySignature(context.beforeTexts), arraySignature(afterTexts))
        end
    elseif kind == "SET_ID" then
        local afterId = type(subject) == "table" and rawget(subject, "id") or nil
        if context.beforeId ~= afterId then
            self:recordMutation(subject, owner, context.routeName, context.beforeId, afterId)
        end
    elseif kind == "SET_STATE" then
        local afterState = type(subject) == "table" and rawget(subject, "state") or nil
        if context.beforeState ~= afterState then
            self:recordMutation(subject, owner, context.routeName, context.beforeState, afterState)
        end
    elseif kind == "CLONE" then
        if type(firstResult) == "table" then
            self:assignOwnerTree(firstResult, owner, false)
        end
    elseif kind == "ADD_ELEMENT" then
        if type(context.arg1) == "table" then
            self:assignOwnerTree(context.arg1, owner, false)
            self:recordMutation(context.arg1, owner, context.routeName, "not attached", "attached")
        end
    elseif kind == "REMOVE_ELEMENT" then
        if type(context.arg1) == "table" then
            self:recordMutation(context.arg1, owner, context.routeName, "attached", "removed")
        end
        self:recordMutation(subject, owner, context.routeName, "child attached", "child removed")
    elseif kind == "EXPOSE_FIELDS" then
        self:recordMutation(subject, owner, context.routeName, "prior field bindings", "refreshed field bindings")
    elseif kind == "LOAD_GUI" and isElement(context.parent) then
        local rootInfo = self:getRootInfo(context.parent)
        local promoted = false
        self:walkTree(context.parent, function(element)
            if context.beforeElements == nil or not context.beforeElements[element] then
                if self:isUsableOwner(owner) then
                    self.ownerByElement[element] = owner
                end
                if rootInfo ~= nil and self.baselineByElement[element] == nil then
                    self:captureBaselineElement(element, rootInfo)
                    if self:isUsableOwner(owner) then
                        self.ownerByElement[element] = owner
                    end
                    promoted = true
                end
            end
        end)
        if promoted and rootInfo ~= nil then
            self:captureRootBindings(rootInfo)
        end
    end
end

function UiIntegrityMonitor:installRoute(container, key, kind, routeName)
    if type(container) ~= "table" or type(container[key]) ~= "function" then
        return false
    end
    local keys = self.routeKeys[container]
    if keys == nil then
        keys = {}
        self.routeKeys[container] = keys
    elseif keys[key] then
        return false
    end

    local observer = self
    local original = container[key]
    local previousRaw = rawget(container, key)
    local wrapper = function(subject, ...)
        local context = observer:beforeRoute(kind, subject, routeName, ...)
        return finishObservedCall(observer, context, original(subject, ...))
    end
    rawset(container, key, wrapper)
    self.originalByWrapper[wrapper] = original
    keys[key] = true
    table.insert(self.routes, {
        container = container,
        key = key,
        kind = kind,
        routeName = routeName,
        original = original,
        previousRaw = previousRaw,
        wrapper = wrapper
    })
    return true
end

function UiIntegrityMonitor:getWrappedOriginal(func)
    return self.originalByWrapper[func]
end

function UiIntegrityMonitor:installClassRoutes()
    local routeCount = 0
    for globalName, container in pairs(_G) do
        if type(globalName) == "string" and type(container) == "table" then
            local isGuiClass = string.sub(globalName, -7) == "Element"
                or string.sub(globalName, -5) == "Frame"
                or globalName == "Gui"
            if isGuiClass then
                for methodName, kind in pairs(ROUTED_METHODS) do
                    if type(rawget(container, methodName)) == "function"
                        and self:installRoute(container, methodName, kind, globalName .. "." .. methodName) then
                        routeCount = routeCount + 1
                    end
                end
                if type(rawget(container, "loadGuiRec")) == "function"
                    and self:installRoute(container, "loadGuiRec", "LOAD_GUI", globalName .. ".loadGuiRec") then
                    routeCount = routeCount + 1
                end
            end
        end
    end

    if type(g_gui) == "table" and self:installRoute(g_gui, "loadGuiRec", "LOAD_GUI", "g_gui.loadGuiRec") then
        routeCount = routeCount + 1
    end
    return routeCount
end

function UiIntegrityMonitor:isCallbackValid(element, value)
    if callbackValueIsEmpty(value) or type(value) == "function" then
        return true
    end
    if type(value) ~= "string" then
        return false
    end
    local target = type(element) == "table" and rawget(element, "target") or nil
    if type(target) == "table" then
        local ok, callback = pcall(function()
            return target[value]
        end)
        if ok and type(callback) == "function" then
            return true
        end
    end
    local ok, callback = pcall(function()
        return element[value]
    end)
    if ok and type(callback) == "function" then
        return true
    end
    return type(rawget(_G, value)) == "function"
end

function UiIntegrityMonitor:addDetection(detections, severity, category, writer, rootInfo, element, evidence, immediate)
    if not self:isUsableOwner(writer) then
        writer = OWNER_UNKNOWN
    end
    local screen = rootInfo ~= nil and rootInfo.label or "GUI"
    local key = table.concat({category, writer, screen}, "|")
    local detection = detections[key]
    if detection == nil then
        detection = {
            key = key,
            severity = severity,
            category = category,
            writer = writer,
            screen = screen,
            problem = CATEGORY_PROBLEMS[category] or "contains suspicious GUI data",
            affected = {},
            affectedSeen = {},
            playerAffected = {},
            playerAffectedSeen = {},
            evidence = {},
            evidenceSeen = {},
            immediate = immediate == true
        }
        detections[key] = detection
    elseif severity == "RED" then
        detection.severity = "RED"
    end
    detection.immediate = detection.immediate or immediate == true
    appendUnique(detection.affected, detection.affectedSeen, self:getElementPath(element, rootInfo), 8)
    appendUnique(detection.playerAffected, detection.playerAffectedSeen, self:getPlayerElementLabel(element), 6)
    appendUnique(detection.evidence, detection.evidenceSeen, evidence, 4)
    return detection
end

function UiIntegrityMonitor:scanBaselineElement(detections, rootInfo, element, snapshot, currentSet)
    if not currentSet[element] then
        local hasDanglingBinding = false
        for _, binding in ipairs(snapshot.fieldBindings or {}) do
            hasDanglingBinding = hasDanglingBinding or rawget(binding.controller, binding.key) == element
        end
        for _, binding in ipairs(snapshot.mapBindings or {}) do
            hasDanglingBinding = hasDanglingBinding or rawget(binding.mapping, element) ~= nil
        end
        if hasDanglingBinding then
            local writer, mutation = self:getMutationWriter(element)
            local evidence = mutation ~= nil
                and (tostring(mutation.operation) .. ": " .. tostring(mutation.beforeText) .. " -> " .. tostring(mutation.afterText))
                or "detached control is still referenced by its controller or settings map"
            self:addDetection(detections, "RED", "STRUCTURE", writer, rootInfo, element, evidence, false)
        end
        return
    end

    local writer = nil
    local mutation = nil
    local function getWriter()
        if writer == nil then
            writer, mutation = self:getMutationWriter(element)
        end
        return writer
    end
    local rawCurrentTexts = rawget(element, "texts")
    local currentTexts = copyArray(rawCurrentTexts)
    if snapshot.texts == nil and type(rawCurrentTexts) == "table" then
        snapshot.texts = currentTexts
    elseif snapshot.texts ~= nil then
        if #snapshot.texts == 0 and currentTexts ~= nil and #currentTexts > 0 then
            -- Many FS25 menus create an empty selector, then populate it when
            -- the screen opens. The first real list becomes the comparison
            -- baseline; initialization is never a conflict.
            snapshot.texts = copyArray(currentTexts)
        elseif not sameArray(snapshot.texts, currentTexts) then
            local observedWriter = getWriter()
            local elementOwner = self.ownerByElement[element]
            local ownedByWriter = self:isUsableOwner(observedWriter)
                and self:isUsableOwner(elementOwner)
                and observedWriter == elementOwner
            local baselinePair = self:getBooleanPairName(snapshot.texts)
            local currentPair = self:getBooleanPairName(currentTexts)
            local stableSettingsControl = #(snapshot.mapBindings or {}) > 0
            local semanticCollision = #snapshot.texts > 0
                and stableSettingsControl
                and baselinePair == nil
                and currentPair ~= nil
            if semanticCollision and not ownedByWriter then
                self:addDetection(
                    detections,
                    "RED",
                    "OPTION_CORRUPTION",
                    observedWriter,
                    rootInfo,
                    element,
                    arraySignature(snapshot.texts) .. " -> " .. arraySignature(currentTexts),
                    true
                )
            end
        end
    end

    for field, baselineCallback in pairs(snapshot.callbacks) do
        local currentCallback = rawget(element, field)
        if currentCallback ~= baselineCallback then
            local valid = self:isCallbackValid(element, currentCallback)
            local baselineWasValid = snapshot.callbackValidity[field] ~= false
            local observedWriter = getWriter()
            if not valid and baselineWasValid and self:isUsableOwner(observedWriter) then
                self:addDetection(
                    detections,
                    "RED",
                    "CALLBACK",
                    observedWriter,
                    rootInfo,
                    element,
                    field .. " changed from " .. tostring(baselineCallback) .. " to " .. tostring(currentCallback),
                    false
                )
            end
        end
    end

end

function UiIntegrityMonitor:validateCurrentElement(detections, rootInfo, element, observedParent)
    local writer = nil
    local function getWriter()
        if writer == nil then
            writer = self:getMutationWriter(element)
        end
        return writer
    end
    if observedParent ~= nil then
        local declaredParent = rawget(element, "parent")
        if declaredParent ~= nil and declaredParent ~= observedParent then
            local observedWriter = getWriter()
            if self:isUsableOwner(observedWriter) then
                self:addDetection(
                    detections,
                    "RED",
                    "PARENT_LINK",
                    observedWriter,
                    rootInfo,
                    element,
                    "parent pointer does not match the tree containing this control",
                    false
                )
            end
        end
    end

    local texts = copyArray(rawget(element, "texts"))
    if type(rawget(element, "texts")) == "table" then
        local state = rawget(element, "state")
        -- Empty selectors are a normal intermediate and sometimes a valid
        -- disabled state. Only a populated selector can prove an invalid
        -- numeric selection.
        if #texts > 0 and type(state) == "number"
            and (state < 1 or state > #texts or state ~= math.floor(state)) then
            local observedWriter = getWriter()
            if self:isUsableOwner(observedWriter) then
                self:addDetection(
                    detections,
                    "RED",
                    "OPTION_STATE",
                    observedWriter,
                    rootInfo,
                    element,
                    string.format("state %s is outside the 1-%d option range", tostring(state), #texts),
                    false
                )
            end
        end
        for _, optionText in ipairs(texts) do
            if hasUnresolvedToken(optionText) then
                local observedWriter = getWriter()
                if self:isUsableOwner(observedWriter) then
                    self:addDetection(
                        detections,
                        "AMBER",
                        "LOCALIZATION",
                        observedWriter,
                        rootInfo,
                        element,
                        "unresolved option text: " .. tostring(optionText),
                        false
                    )
                end
                break
            end
        end
    end

    local textValue = rawget(element, "text")
    if hasUnresolvedToken(textValue) then
        local observedWriter = getWriter()
        if self:isUsableOwner(observedWriter) then
            self:addDetection(
                detections,
                "AMBER",
                "LOCALIZATION",
                observedWriter,
                rootInfo,
                element,
                "unresolved text: " .. tostring(textValue),
                false
            )
        end
    end

    for _, field in ipairs(CALLBACK_FIELDS) do
        local callback = rawget(element, field)
        local baseline = self.baselineByElement[element]
        local callbackChanged = baseline ~= nil and baseline.callbacks[field] ~= callback
        local isModOwned = self:isUsableOwner(self.ownerByElement[element])
        if not callbackValueIsEmpty(callback)
            and not self:isCallbackValid(element, callback)
            and (callbackChanged or isModOwned) then
            local observedWriter = getWriter()
            if self:isUsableOwner(observedWriter) then
                self:addDetection(
                    detections,
                    "RED",
                    "CALLBACK",
                    observedWriter,
                    rootInfo,
                    element,
                    field .. " points to missing callback '" .. tostring(callback) .. "'",
                    false
                )
            end
        end
    end

    for _, field in ipairs(GEOMETRY_FIELDS) do
        local values = rawget(element, field)
        if type(values) == "table" then
            for index, value in ipairs(values) do
                if not isFiniteNumber(value) then
                    local observedWriter = getWriter()
                    if self:isUsableOwner(observedWriter) then
                        self:addDetection(
                            detections,
                            "RED",
                            "GEOMETRY",
                            observedWriter,
                            rootInfo,
                            element,
                            field .. "[" .. tostring(index) .. "] is NaN or infinite",
                            false
                        )
                    end
                    break
                end
            end
        end
    end
end

function UiIntegrityMonitor:scanRoot(detections, rootInfo)
    local currentSet = setmetatable({}, {__mode = "k"})
    local siblingIdCounts = setmetatable({}, {__mode = "k"})
    local siblingIdElements = setmetatable({}, {__mode = "k"})
    local currentEntries = {}
    self:walkTree(rootInfo.root, function(element, parent)
        currentSet[element] = true
        self.rootForElement[element] = rootInfo
        table.insert(currentEntries, {element = element, parent = parent})
        local id = rawget(element, "id")
        if type(id) == "string" and id ~= "" then
            local bucketKey = parent or rootInfo.rootIdBucket
            local counts = siblingIdCounts[bucketKey]
            local elements = siblingIdElements[bucketKey]
            if counts == nil then
                counts = {}
                elements = {}
                siblingIdCounts[bucketKey] = counts
                siblingIdElements[bucketKey] = elements
            end
            counts[id] = (counts[id] or 0) + 1
            elements[id] = elements[id] or element
        end
    end)

    if self:refreshReplacedLayout(rootInfo, currentSet) then
        return
    end

    for _, entry in ipairs(currentEntries) do
        self:validateCurrentElement(detections, rootInfo, entry.element, entry.parent)
    end

    for element, snapshot in pairs(rootInfo.baselineElements or {}) do
        self:scanBaselineElement(detections, rootInfo, element, snapshot, currentSet)
    end

    for bucketKey, counts in pairs(siblingIdCounts) do
        local baselineCounts = rootInfo.baselineSiblingIdCounts[bucketKey] or {}
        for id, currentCount in pairs(counts) do
            local baselineCount = baselineCounts[id] or 0
            if currentCount > 1 and currentCount > baselineCount then
                local element = siblingIdElements[bucketKey][id]
                local writer = self:getMutationWriter(element)
                self:addDetection(
                    detections,
                    "AMBER",
                    "DUPLICATE_ID",
                    writer,
                    rootInfo,
                    element,
                    string.format("sibling ID '%s' appears %d times (baseline %d)", id, currentCount, baselineCount),
                    false
                )
            end
        end
    end
end

function UiIntegrityMonitor:addSetupEventDetections(detections)
    local redScopes = {}
    for _, detection in pairs(detections) do
        if detection.severity == "RED" then
            redScopes[detection.writer .. "|" .. detection.screen] = true
        end
    end
    for _, event in pairs(self.setupEvents) do
        local screen = event.rootInfo ~= nil and event.rootInfo.label or "GUI"
        if not redScopes[event.owner .. "|" .. screen] then
            self:addDetection(
                detections,
                "AMBER",
                "WHOLE_SCREEN_SETUP",
                event.owner,
                event.rootInfo,
                event.element,
                string.format("mod-triggered setup traversed %d existing elements", event.count),
                true
            )
        end
    end
end

function UiIntegrityMonitor:publishDetections(detections)
    local nextCounts = {}
    local published = false
    for key, detection in pairs(detections) do
        local count = (self.candidateCounts[key] or 0) + 1
        nextCounts[key] = count
        if detection.immediate or count >= REPORT_AFTER_SCANS then
            detection.evidenceText = table.concat(detection.evidence, "; ")
            detection.affectedText = table.concat(detection.affected, ", ")
            detection.playerAffectedText = table.concat(detection.playerAffected, ", ")
            detection.affectedSeen = nil
            detection.playerAffectedSeen = nil
            detection.evidenceSeen = nil
            local signature = table.concat({
                detection.severity,
                detection.writer,
                detection.screen,
                detection.problem,
                detection.affectedText,
                detection.evidenceText
            }, "|")
            if self.publishedSignatures[key] ~= signature then
                self.publishedSignatures[key] = signature
                self:log(
                    "%s %s: %s on %s; affected=%s; evidence=%s",
                    detection.severity,
                    detection.category,
                    detection.writer,
                    detection.screen,
                    detection.affectedText,
                    detection.evidenceText
                )
            end
            if self.host ~= nil and type(self.host.raiseUiIssue) == "function" then
                self.host:raiseUiIssue(detection)
            end
            published = true
        end
    end
    self.candidateCounts = nextCounts
    return published
end

function UiIntegrityMonitor:scan()
    self.scanNumber = self.scanNumber + 1
    self:discoverRoots()
    local detections = {}
    for _, rootInfo in ipairs(self.roots) do
        self:scanRoot(detections, rootInfo)
    end
    self:addSetupEventDetections(detections)
    return self:publishDetections(detections)
end

function UiIntegrityMonitor:install()
    if self.installed then
        return
    end
    self.installed = true
    self.installing = true
    self:installClassRoutes()
    self:discoverRoots()
    self.installing = false
    self:log(
        "general GUI integrity monitor armed on %d route(s) across %d screen root(s)",
        #self.routes,
        #self.roots
    )
end

function UiIntegrityMonitor:resetSession()
    self.setupEvents = {}
    self.candidateCounts = {}
    self.publishedSignatures = {}
    self.scanNumber = 0
end

function UiIntegrityMonitor:delete()
    for index = #self.routes, 1, -1 do
        local route = self.routes[index]
        if rawget(route.container, route.key) == route.wrapper then
            rawset(route.container, route.key, route.previousRaw)
        end
    end
    self.routes = {}
    self.routeKeys = setmetatable({}, {__mode = "k"})
    self.originalByWrapper = setmetatable({}, {__mode = "k"})
    self.installed = false
    self.installing = false
    self.setupDepth = 0
end
