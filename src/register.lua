--
-- Script Sentry
-- Read-only confirmed-conflict, GUI-integrity, and safe FPS diagnostics for Farming Simulator 25.
--

local modDirectory = g_currentModDirectory
local modName = g_currentModName

source(Utils.getFilename("src/HookAlertHud.lua", modDirectory))
source(Utils.getFilename("src/PerformanceMonitor.lua", modDirectory))
source(Utils.getFilename("src/UiIntegrityMonitor.lua", modDirectory))
source(Utils.getFilename("src/HookAlert.lua", modDirectory))

g_scriptSentry = HookAlert.new(modDirectory, modName)
g_scriptSentry:install()
addModEventListener(g_scriptSentry)
