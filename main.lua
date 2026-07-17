-- =========================================================
-- FS25_TimeGuard - mod entry point
-- =========================================================
-- Author: TisonK
-- =========================================================
-- Loads the Time Guard modules, publishes the g_timeGuard handle, and
-- hooks the FS25 mission lifecycle:
--   Mission00.load                     -> publish the cross-mod bridge handle
--   Mission00.loadMission00Finished    -> seed the clock, subscribe to the
--                                         calendar events, bind bedrock
--   FSBaseMission.update               -> drive the client join-sync retry
--   FSCareerMissionInfo.saveToXMLFile  -> persist the accrual cursors (own-file
--                                         fallback; StateLedger handles it when present)
--   FSBaseMission.delete               -> unsubscribe + drop the handle
--
-- Load order: Time Guard is the 5th core service (after StateLedger,
-- NetworkSync, MasterHUD, SettingsHub). The handle is published as soon as
-- this file runs so companion mods that load after it can subscribe /
-- registerAccrual during their own module load, before the mission exists.
-- =========================================================

local modDirectory = g_currentModDirectory

source(modDirectory .. "src/Logger.lua")
source(modDirectory .. "src/TimeGuardScheduler.lua")
source(modDirectory .. "src/TimeGuard.lua")

-- Create the instance and publish the handle immediately (before any
-- mission hook), so early companion registrations are never missed.
local timeGuard = TimeGuard.new()
getfenv(0)["g_timeGuard"] = timeGuard

-- ---------------------------------------------------------
-- Mission lifecycle hooks
-- ---------------------------------------------------------

local function onMissionLoad(mission)
    -- g_currentMission is a shared C++ object visible to all mods, unlike
    -- getfenv(0) which is per-mod scoped. Publish the cross-mod bridge here.
    if mission ~= nil then
        mission.timeGuard = timeGuard
    end
    TGLogger.info("Time Guard active (mod 5, economic clock)")
end

local function onMissionLoadedFinished()
    timeGuard:onMissionLoaded()
end

local function onMissionUpdate(mission, dt)
    timeGuard:update(dt)
end

local function onMissionSave()
    timeGuard:save()
end

local function onMissionDelete()
    timeGuard:onMissionDelete()
    getfenv(0)["g_timeGuard"] = nil
    if g_currentMission ~= nil then
        g_currentMission.timeGuard = nil
    end
end

-- appendedFunction so the base game's own handler runs first.
Mission00.load = Utils.appendedFunction(Mission00.load, onMissionLoad)
Mission00.loadMission00Finished = Utils.appendedFunction(Mission00.loadMission00Finished, onMissionLoadedFinished)
FSBaseMission.update = Utils.appendedFunction(FSBaseMission.update, onMissionUpdate)

-- Save via FSCareerMissionInfo:saveToXMLFile, the window where
-- savegameDirectory points at the tempsavegame that FS25 then copies over the
-- real savegame. Hooking the non-existent Mission00.saveToXMLFile is a known
-- trap that silently never fires.
if FSCareerMissionInfo ~= nil and FSCareerMissionInfo.saveToXMLFile ~= nil then
    FSCareerMissionInfo.saveToXMLFile = Utils.appendedFunction(
        FSCareerMissionInfo.saveToXMLFile,
        function() onMissionSave() end
    )
else
    TGLogger.warning("FSCareerMissionInfo.saveToXMLFile not found - accrual cursors will NOT be saved")
end

FSBaseMission.delete = Utils.prependedFunction(FSBaseMission.delete, onMissionDelete)

-- ---------------------------------------------------------
-- Console command: tgStatus (target + method, the proven pattern)
-- ---------------------------------------------------------

if addConsoleCommand ~= nil then
    addConsoleCommand("tgStatus", "Show Time Guard clock state, subscribers, and accruals",
        "consoleCommandStatus", timeGuard)
end
