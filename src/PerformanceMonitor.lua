--
-- Script Sentry safe frame-rate check.
--
-- Version 0.5.2 and later deliberately do not wrap mod event listeners,
-- specialization callbacks, or Utils.*Function hook callbacks. The earlier
-- profiler put Script Sentry into live gameplay call chains even when no scan
-- was running. That made error stacks misleading and created an unnecessary
-- compatibility risk for a read-only diagnostic mod.
--
-- The on-demand check now measures only frame timing supplied to Script
-- Sentry's own update method. It can confirm that a slowdown or stutter was
-- captured, but it never guesses which mod caused it.
--

PerformanceMonitor = {}
local PerformanceMonitor_mt = Class(PerformanceMonitor)

local SCRIPT_SENTRY_VERSION = "0.5.3.0"
local SCAN_DURATION_MS = 15000
local SLOW_FRAME_MS = 1000 / 30
local SEVERE_FRAME_MS = 50

function PerformanceMonitor.new(modDirectory, modName, customMt)
    local self = setmetatable({}, customMt or PerformanceMonitor_mt)
    self.modDirectory = modDirectory
    self.modName = modName
    self.currentOwner = nil
    self.executingOwner = nil
    self.missionReady = false
    self.sampling = false
    self.sampleElapsedMs = 0
    self.sampleFrameMs = 0
    self.sampleFrames = 0
    self.maxFrameMs = 0
    self.slowFrameCount = 0
    self.severeFrameCount = 0
    self.reportText = nil
    self.reportKind = "INFO"
    self.dialogOpen = false
    self.pendingOpen = false
    self.guiFailureReported = false
    return self
end

function PerformanceMonitor:log(message, ...)
    if select("#", ...) > 0 then
        message = string.format(message, ...)
    end
    print("[ScriptSentry Performance] " .. message)
end

-- Compatibility methods retained for HookAlert and older internal callers.
-- They intentionally never claim an active or wrapped callback owner.
function PerformanceMonitor:setCurrentOwner(owner)
    self.currentOwner = owner
end

function PerformanceMonitor:getWrappedOwner(func)
    return nil
end

function PerformanceMonitor:getExecutingOwner()
    return nil
end

-- Fail-safe pass-through: even if a future caller accidentally invokes this
-- legacy entry point, the exact original hook function is returned.
function PerformanceMonitor:wrapHook(kind, hookFunc, owner)
    return hookFunc
end

function PerformanceMonitor:registerListener(listener, owner)
    return false
end

function PerformanceMonitor:registerSpecializationCallback(eventName, specClass)
    return false
end

function PerformanceMonitor:install()
    self:log(
        "v%s safe FPS check armed; no gameplay hooks, listeners, or specialization callbacks are wrapped",
        SCRIPT_SENTRY_VERSION
    )
end

function PerformanceMonitor:restoreObservers()
    -- No performance observers are installed in safe mode.
end

function PerformanceMonitor:onMissionReady()
    if self.missionReady then
        return
    end
    self.missionReady = true
    self:log("safe FPS check ready; callback identity remains unchanged")
end

function PerformanceMonitor:notify(text)
    if g_currentMission == nil then
        return
    end
    if type(g_currentMission.addIngameNotification) == "function"
        and type(FSBaseMission) == "table"
        and FSBaseMission.INGAME_NOTIFICATION_INFO ~= nil then
        local ok = pcall(
            g_currentMission.addIngameNotification,
            g_currentMission,
            FSBaseMission.INGAME_NOTIFICATION_INFO,
            text
        )
        if ok then
            return
        end
    end
    if type(g_currentMission.showBlinkingWarning) == "function" then
        pcall(g_currentMission.showBlinkingWarning, g_currentMission, text, 5000)
    end
end

function PerformanceMonitor:resetMeasurements()
    self.sampleElapsedMs = 0
    self.sampleFrameMs = 0
    self.sampleFrames = 0
    self.maxFrameMs = 0
    self.slowFrameCount = 0
    self.severeFrameCount = 0
end

function PerformanceMonitor:startScan()
    if not self.missionReady or g_currentMission == nil then
        self:notify("Script Sentry: wait until the save has finished loading, then run the check again.")
        return false
    end
    if self.sampling then
        local remaining = math.max(0, SCAN_DURATION_MS - self.sampleElapsedMs) / 1000
        self:notify(string.format("Script Sentry: FPS check is running - %.0f seconds remaining.", remaining))
        return false
    end

    self:resetMeasurements()
    self.reportText = nil
    self.pendingOpen = false
    self.sampling = true
    self:notify("Script Sentry: safe FPS check started. Reproduce the slowdown for 15 seconds.")
    self:log("safe FPS check started - reproduce the slowdown for 15 seconds")
    return true
end

function PerformanceMonitor:buildReport()
    local frames = math.max(1, self.sampleFrames)
    local averageFrameMs = self.sampleFrameMs / frames
    local averageFps = averageFrameMs > 0 and 1000 / averageFrameMs or 0
    local slowestFps = self.maxFrameMs > 0 and 1000 / self.maxFrameMs or 0
    local slowPercent = self.slowFrameCount * 100 / frames
    local severePercent = self.severeFrameCount * 100 / frames
    local lines = {
        string.format("SCRIPT SENTRY %s - SAFE FPS CHECK", SCRIPT_SENTRY_VERSION),
        string.format("Average speed: %.0f FPS", averageFps),
        string.format("Slowest moment: %.0f FPS", slowestFps),
        string.format("Frames below 30 FPS: %d of %d", self.slowFrameCount, self.sampleFrames),
        ""
    }

    if averageFps < 45 or severePercent >= 5 then
        table.insert(lines, "Result: the slowdown was captured during this test.")
        table.insert(lines, "What to do: disable half of the suspected mods, repeat the same test, then narrow the group.")
        self.reportKind = "WARNING"
    elseif self.severeFrameCount > 0 or slowPercent >= 1 then
        table.insert(lines, "Result: normal speed overall, but one or more stutters were captured.")
        table.insert(lines, "What to do: repeat the test in the same place. If it repeats, test recent mods in halves.")
        self.reportKind = "WARNING"
    else
        table.insert(lines, "Result: no sustained slowdown was captured.")
        table.insert(lines, "What to do: run the check again while the problem is visible.")
        self.reportKind = "INFO"
    end

    table.insert(lines, "")
    table.insert(lines, "No mod is named by this check.")
    table.insert(lines, "Reason: the unsafe per-mod callback wrappers were removed in this patch.")
    table.insert(lines, "SPACE: CLOSE    |    RIGHT ALT + 2: RUN ANOTHER 15-SECOND CHECK")

    self:log(
        "safe check complete: frames=%d avgFrameMs=%.3f avgFps=%.1f maxFrameMs=%.3f slowFrames=%d severeFrames=%d",
        self.sampleFrames,
        averageFrameMs,
        averageFps,
        self.maxFrameMs,
        self.slowFrameCount,
        self.severeFrameCount
    )
    return table.concat(lines, "\n")
end

function PerformanceMonitor:getIsGuiVisible()
    if g_gui == nil or type(g_gui.getIsGuiVisible) ~= "function" then
        return false
    end
    local ok, visible = pcall(g_gui.getIsGuiVisible, g_gui)
    return ok and visible == true
end

function PerformanceMonitor:getDialogType()
    if type(DialogElement) ~= "table" then
        return nil
    end
    if self.reportKind == "WARNING" then
        return DialogElement.TYPE_WARNING or DialogElement.TYPE_INFO
    end
    return DialogElement.TYPE_INFO or DialogElement.TYPE_WARNING
end

function PerformanceMonitor:openReport()
    if self.reportText == nil or self.dialogOpen then
        return false
    end
    if self:getIsGuiVisible() then
        self.pendingOpen = true
        return false
    end

    local hasStaticInfoDialog = type(InfoDialog) == "table" and type(InfoDialog.show) == "function"
    local hasGuiInfoDialog = g_gui ~= nil and type(g_gui.showInfoDialog) == "function"
    if not hasStaticInfoDialog and not hasGuiInfoDialog then
        if not self.guiFailureReported then
            self.guiFailureReported = true
            self:log("ERROR: FS25's InfoDialog service is unavailable")
        end
        return false
    end

    local dialogType = self:getDialogType()
    local buttonAction = nil
    if type(InputAction) == "table" and InputAction.MENU_ACTIVATE ~= nil then
        buttonAction = InputAction.MENU_ACTIVATE
    end

    local ok
    local errorMessage
    if hasStaticInfoDialog then
        ok, errorMessage = pcall(
            InfoDialog.show,
            self.reportText,
            PerformanceMonitor.onDialogClosed,
            self,
            dialogType,
            "CLOSE",
            buttonAction
        )
    else
        ok, errorMessage = pcall(g_gui.showInfoDialog, g_gui, {
            text = self.reportText,
            callback = PerformanceMonitor.onDialogClosed,
            target = self,
            dialogType = dialogType,
            okText = "CLOSE",
            buttonAction = buttonAction
        })
    end

    if not ok then
        self.pendingOpen = false
        if not self.guiFailureReported then
            self.guiFailureReported = true
            self:log("ERROR: could not open FPS report: %s", tostring(errorMessage))
        end
        return false
    end

    self.dialogOpen = true
    self.pendingOpen = false
    return true
end

function PerformanceMonitor:onDialogClosed(...)
    self.dialogOpen = false
    self.pendingOpen = false
    self:log("FPS report closed - RIGHT ALT + 2 runs a fresh safe check")
end

function PerformanceMonitor:finishScan()
    if not self.sampling then
        return
    end
    self.sampling = false
    self.reportText = self:buildReport()
    self:openReport()
end

function PerformanceMonitor:update(dt)
    if self.pendingOpen and not self.dialogOpen and not self:getIsGuiVisible() then
        self:openReport()
    end
    if not self.sampling then
        return
    end

    if type(dt) == "number" and dt > 0 and dt < 1000 then
        self.sampleElapsedMs = self.sampleElapsedMs + dt
        self.sampleFrameMs = self.sampleFrameMs + dt
        self.sampleFrames = self.sampleFrames + 1
        self.maxFrameMs = math.max(self.maxFrameMs, dt)
        if dt >= SLOW_FRAME_MS then
            self.slowFrameCount = self.slowFrameCount + 1
        end
        if dt >= SEVERE_FRAME_MS then
            self.severeFrameCount = self.severeFrameCount + 1
        end
    end

    if self.sampleElapsedMs >= SCAN_DURATION_MS then
        self:finishScan()
    end
end

function PerformanceMonitor:handleAction()
    self:startScan()
end

function PerformanceMonitor:loadMap()
    self.missionReady = false
    self.sampling = false
    self.pendingOpen = false
    self.dialogOpen = false
    self.reportText = nil
    self:resetMeasurements()
end

function PerformanceMonitor:deleteMap()
    self.sampling = false
    self.pendingOpen = false
    self.dialogOpen = false
    self:restoreObservers()
end

function PerformanceMonitor:delete()
    self:deleteMap()
end
