--
-- Script Sentry review dialog.
--
-- Results are displayed with FS25's native modal dialog system. This keeps the
-- review visible until the player closes it, puts input into the game's menu
-- context while it is open, and leaves no persistent HUD element behind.
--

HookAlertHud = {}
local HookAlertHud_mt = Class(HookAlertHud)

local ITEMS_PER_PAGE = 1

local function shorten(text, maximum)
    text = tostring(text or "")
    if string.len(text) <= maximum then
        return text
    end
    return string.sub(text, 1, maximum - 3) .. "..."
end

local function copyItems(items)
    local result = {}
    for _, item in ipairs(items or {}) do
        table.insert(result, {
            kind = item.kind or "INFO",
            label = item.label or "INFO",
            primary = item.primary or "",
            secondary = item.secondary or "",
            evidence = item.evidence or "",
            advice = item.advice or ""
        })
    end
    return result
end

function HookAlertHud.new(customMt)
    local self = setmetatable({}, customMt or HookAlertHud_mt)
    self.review = nil
    self.pages = {}
    self.currentPage = 1
    self.dialogOpen = false
    self.pendingOpen = false
    self.guiFailureReported = false
    self.startupSequence = false
    self.startupHandoffDelay = 0
    return self
end

function HookAlertHud:getStartupOwner()
    if g_currentMission == nil then
        return nil
    end
    return g_currentMission.dmDiagnosticStartupReviewOwner
end

function HookAlertHud:claimStartupOwnership()
    if g_currentMission == nil then
        return true
    end

    local owner = self:getStartupOwner()
    if owner ~= nil and owner ~= self then
        return false
    end

    g_currentMission.dmDiagnosticStartupReviewOwner = self
    return true
end

function HookAlertHud:releaseStartupOwnership()
    if g_currentMission ~= nil
        and g_currentMission.dmDiagnosticStartupReviewOwner == self then
        g_currentMission.dmDiagnosticStartupReviewOwner = nil
    end
end

function HookAlertHud:cancelStartupSequence()
    self.startupSequence = false
    self.startupHandoffDelay = 0
    self:releaseStartupOwnership()
end

function HookAlertHud:reset()
    self:cancelStartupSequence()
    self.dialogOpen = false
    self.pendingOpen = false
    self.currentPage = 1
end

function HookAlertHud:setReview(kind, title, summary, detail, items)
    self.review = {
        kind = kind or "INFO",
        title = title or "SCRIPT SENTRY 0.5.3.0 - CHECK COMPLETE",
        summary = summary or "",
        detail = detail or "",
        items = copyItems(items)
    }
    self.currentPage = 1
    self:rebuildPages()
end

function HookAlertHud:rebuildPages()
    self.pages = {}
    if self.review == nil then
        return
    end

    local items = self.review.items
    if #items == 0 then
        table.insert(self.pages, {})
        return
    end

    local page = nil
    for index, item in ipairs(items) do
        if (index - 1) % ITEMS_PER_PAGE == 0 then
            page = {}
            table.insert(self.pages, page)
        end
        table.insert(page, item)
    end
end

function HookAlertHud:getPageCount()
    return math.max(1, #self.pages)
end

function HookAlertHud:buildPageText(pageIndex)
    if self.review == nil then
        return "SCRIPT SENTRY\n\nStartup scan is still in progress.\n\nSPACE: CLOSE\nRIGHT ALT + 1: VIEW AGAIN"
    end

    local pageCount = self:getPageCount()
    pageIndex = math.max(1, math.min(pageCount, pageIndex or 1))
    local page = self.pages[pageIndex] or {}
    local lines = {
        self.review.title,
        self.review.summary
    }

    if self.review.detail ~= "" then
        table.insert(lines, self.review.detail)
    end

    if #page > 0 then
        table.insert(lines, "")
        for _, item in ipairs(page) do
            table.insert(lines, shorten(item.primary, 104))
            table.insert(lines, shorten(item.secondary, 110))
            if item.evidence ~= "" then
                table.insert(lines, shorten(item.evidence, 110))
            end
            table.insert(lines, shorten(item.advice, 108))
        end
    end

    table.insert(lines, "")
    table.insert(lines, string.format("PAGE %d OF %d    |    SPACE: CLOSE", pageIndex, pageCount))
    if pageCount > 1 then
        local nextPage = pageIndex % pageCount + 1
        table.insert(lines, string.format(
            "After closing, press RIGHT ALT + 1 for page %d. The shortcut cycles every review page.",
            nextPage
        ))
    else
        table.insert(lines, "Press RIGHT ALT + 1 at any time to open this review again.")
    end

    return table.concat(lines, "\n")
end

function HookAlertHud:getDialogType()
    if type(DialogElement) ~= "table" then
        return nil
    end
    if self.review ~= nil and self.review.kind == "OVERWRITE" then
        return DialogElement.TYPE_ERROR or DialogElement.TYPE_WARNING
    end
    if self.review ~= nil and self.review.kind == "OVERLAP" then
        return DialogElement.TYPE_WARNING or DialogElement.TYPE_INFO
    end
    return DialogElement.TYPE_INFO or DialogElement.TYPE_WARNING
end

function HookAlertHud:getIsGuiVisible()
    if g_gui == nil or type(g_gui.getIsGuiVisible) ~= "function" then
        return false
    end
    local ok, visible = pcall(g_gui.getIsGuiVisible, g_gui)
    return ok and visible == true
end

function HookAlertHud:openReview(resetToFirstPage, startupSequence)
    if resetToFirstPage then
        self.currentPage = 1
    end
    if startupSequence ~= nil then
        self.startupSequence = startupSequence == true
        self.startupHandoffDelay = 0
        if not self.startupSequence then
            self:releaseStartupOwnership()
        end
    end
    if self.dialogOpen then
        return false
    end
    if self.review == nil then
        self:setReview(
            "INFO",
            "SCRIPT SENTRY 0.5.3.0 - SCAN IN PROGRESS",
            "The startup review is not ready yet.",
            "It will open automatically when the scan finishes.",
            {}
        )
    end

    if self.startupSequence then
        local owner = self:getStartupOwner()
        if owner ~= nil and owner ~= self then
            self.pendingOpen = true
            -- Leave a small quiet window after the other startup dialog
            -- releases ownership. FS25 reuses one native InfoDialog instance,
            -- so reopening it in the same close callback can mix callbacks.
            self.startupHandoffDelay = 250
            return false
        end
    end

    local hasStaticInfoDialog = type(InfoDialog) == "table"
        and type(InfoDialog.show) == "function"
    local hasGuiInfoDialog = g_gui ~= nil
        and type(g_gui.showInfoDialog) == "function"
    if not hasStaticInfoDialog and not hasGuiInfoDialog then
        self.pendingOpen = false
        self:cancelStartupSequence()
        if not self.guiFailureReported then
            self.guiFailureReported = true
            print("[ScriptSentry] ERROR: FS25's InfoDialog service is unavailable")
        end
        return false
    end

    if self:getIsGuiVisible() then
        self.pendingOpen = true
        if self.startupSequence then
            self.startupHandoffDelay = 250
        end
        return false
    end


    if self.startupSequence and not self:claimStartupOwnership() then
        self.pendingOpen = true
        self.startupHandoffDelay = 250
        return false
    end

    local text = self:buildPageText(self.currentPage)
    local callback = HookAlertHud.onDialogClosed
    local dialogType = self:getDialogType()
    local buttonAction = nil
    if type(InputAction) == "table" and InputAction.MENU_ACTIVATE ~= nil then
        buttonAction = InputAction.MENU_ACTIVATE
    end

    local args = {
        text = text,
        callback = callback,
        target = self,
        okText = "CLOSE"
    }
    if dialogType ~= nil then
        args.dialogType = dialogType
    end
    if buttonAction ~= nil then
        -- MENU_ACTIVATE is already SPACE in the player's supplied profile. By
        -- reusing it as the dialog button action, no second SPACE binding is
        -- installed and gameplay actions remain outside the modal GUI context.
        args.buttonAction = buttonAction
    end

    local ok
    local errorMessage
    if hasStaticInfoDialog then
        -- FS25's current convenience API. The sixth argument selects the
        -- existing input action shown and consumed by the dialog button.
        ok, errorMessage = pcall(
            InfoDialog.show,
            text,
            callback,
            self,
            dialogType,
            "CLOSE",
            buttonAction
        )
    else
        -- Compatibility path retained for game builds exposing the older Gui
        -- convenience method instead of InfoDialog.show.
        ok, errorMessage = pcall(g_gui.showInfoDialog, g_gui, args)
    end
    if not ok then
        self.pendingOpen = false
        self:cancelStartupSequence()
        if not self.guiFailureReported then
            self.guiFailureReported = true
            print("[ScriptSentry] ERROR: Could not open startup review: " .. tostring(errorMessage))
        end
        return false
    end

    self.dialogOpen = true
    self.pendingOpen = false
    print(string.format(
        "[ScriptSentry] Review dialog opened: page %d/%d",
        self.currentPage,
        self:getPageCount()
    ))
    return true
end

function HookAlertHud:onDialogClosed(...)
    self.dialogOpen = false
    self.pendingOpen = false
    local wasStartupSequence = self.startupSequence
    self:cancelStartupSequence()
    local pageCount = self:getPageCount()
    if pageCount > 1 then
        self.currentPage = self.currentPage % pageCount + 1
    else
        self.currentPage = 1
    end
    if wasStartupSequence then
        print("[ScriptSentry] Startup review closed - startup dialog ownership released")
    else
        print("[ScriptSentry] Review dialog closed - press RIGHT ALT + 1 to view it again")
    end
end

function HookAlertHud:update(dt)
    if not self.pendingOpen or self.dialogOpen then
        return
    end

    if self.startupSequence then
        local owner = self:getStartupOwner()
        if (owner ~= nil and owner ~= self) or self:getIsGuiVisible() then
            self.startupHandoffDelay = 250
            return
        end

        self.startupHandoffDelay = math.max(0, self.startupHandoffDelay - (dt or 0))
        if self.startupHandoffDelay > 0 then
            return
        end
    elseif self:getIsGuiVisible() then
        return
    end

    self:openReview(false)
end

function HookAlertHud:draw()
    -- The native InfoDialog is rendered by FS25. Deliberately draw nothing
    -- here so there is no badge, icon, or alert left on the gameplay HUD.
end
