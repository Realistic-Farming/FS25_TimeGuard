-- =========================================================
-- FS25_TimeGuard - core class (the economic clock)
-- =========================================================
-- Author: TisonK
-- =========================================================
-- The 5th core service. Subscribes to the game's in-game calendar events and
-- republishes canonical economic ticks, normalizes the days-per-month setting
-- in one place, and drives the accrue-and-settle scheduler.
--
-- Rule 10: cadence rides the in-game calendar events (DAY_CHANGED /
-- PERIOD_CHANGED / HOUR_CHANGED), never accumulated dt and never a real clock,
-- so it is timeScale-independent by construction. See the calendar API notes:
--   MessageType.PERIOD_CHANGED -> a period is a MONTH (currentPeriod 1..12).
--   There is no YEAR event; the year is counted from PERIOD_CHANGED rollovers.
--
-- Money-safety fence: this class NEVER calls addMoney. Settlement invokes the
-- owner's callback; the owner writes its own money.
-- =========================================================

TimeGuard = {}
local TimeGuard_mt = Class(TimeGuard)

local DAY_MS = 24 * 60 * 60 * 1000   -- 86,400,000 ms (confirmed vs AbstractMission)
local PERIODS_PER_YEAR = 12          -- FS25: 12 periods (months) per year

-- The suite's canonical month length for CALENDAR-rated burden invariance. A
-- per-day rate passed through normalizePerDay() is scaled so a whole month
-- always carries the weight of REFERENCE_DAYS_PER_PERIOD days regardless of the
-- player's days-per-month setting. The balance pass owns this number.
TimeGuard.REFERENCE_DAYS_PER_PERIOD = 30

TimeGuard.SAVE_FILE      = "RealisticFarming_TimeGuard.xml"   -- own-file fallback
TimeGuard.LEDGER_MODULE  = "FS25_TimeGuard"                    -- id in StateLedger/NetworkSync/SettingsHub

function TimeGuard.new()
    local self = setmetatable({}, TimeGuard_mt)

    self.scheduler = TimeGuardScheduler.new(self)

    -- Calendar state (seeded at boot, maintained by the message handlers).
    self.seeded        = false
    self.daysPerPeriod = 1
    self.currentPeriod = 1     -- 1..12
    self.monthCounter  = 0     -- monotonic month index (year*12 + period-1)
    self.yearCounter   = 0     -- monotonic year index

    -- Tick subscribers (display/read; fire on all peers).
    self.tickSubs      = { hour = {}, day = {}, month = {}, year = {} }
    self.tickSubOrder  = { hour = {}, day = {}, month = {}, year = {} }

    -- Core-service state.
    self.enabled       = true
    self.synced        = false
    self.bedrockBound  = false
    self.ledgerBound   = false
    self.networkSyncBound = false
    self.settingsHubBound = false
    self.messagesBound = false
    self.ledgerRestored = false

    return self
end

-- =========================================================
-- Lifecycle
-- =========================================================

function TimeGuard:onMissionLoaded()
    self:_seedClock()
    self:_subscribeCalendar()
    self:_bindBedrock()

    -- Own-file fallback: only when StateLedger is absent (else it delivers the
    -- cursors through the registered deserialize callback).
    local ledger = self:_getLedger()
    if ledger == nil then
        self:_loadOwnFile()
    end

    -- The server is authoritative; a client is "synced" once its own clock is
    -- seeded from the engine-synced environment (NetworkSync corrects it later
    -- when present).
    self.synced = (g_currentMission ~= nil and g_currentMission:getIsServer()) or self.seeded
    TGLogger.info("Clock seeded: year=%d period=%d daysPerPeriod=%d monthCounter=%d",
        self.yearCounter, self.currentPeriod, self.daysPerPeriod, self.monthCounter)
end

function TimeGuard:update(dt)
    -- The ticks are event-driven; update only retries a deferred bedrock bind
    -- (a core service may finish loading after us).
    if not self.bedrockBound then
        self:_bindBedrock()
    end
end

function TimeGuard:onMissionDelete()
    if self.messagesBound and g_messageCenter ~= nil then
        g_messageCenter:unsubscribeAll(self)
        self.messagesBound = false
    end
    self.seeded       = false
    self.bedrockBound = false
    self.ledgerBound  = false
    self.networkSyncBound = false
    self.settingsHubBound = false
    self.synced       = false
end

function TimeGuard:save()
    -- StateLedger, when present, persists the cursors through its own save. Only
    -- write the own-file fallback when StateLedger is absent.
    if self:_getLedger() ~= nil then
        return
    end
    if g_currentMission == nil or not g_currentMission:getIsServer() then
        return
    end
    self:_saveOwnFile()
end

-- =========================================================
-- Clock seed + calendar subscriptions
-- =========================================================

function TimeGuard:_env()
    return g_currentMission ~= nil and g_currentMission.environment or nil
end

function TimeGuard:_seedClock()
    local env = self:_env()
    self.daysPerPeriod = (env and env.daysPerPeriod) or 1
    if self.daysPerPeriod < 1 then self.daysPerPeriod = 1 end

    local period = env and env.currentPeriod or nil
    local year   = env and env.currentYear or nil

    if period == nil or year == nil then
        -- Fallback: derive from the monotonic day when the calendar fields are
        -- not readable (documented relative-from-start fallback).
        local mday = (env and env.currentMonotonicDay) or 1
        local daysPerYear = PERIODS_PER_YEAR * self.daysPerPeriod
        year   = year   or math.floor((mday - 1) / daysPerYear)
        period = period or (math.floor(((mday - 1) % daysPerYear) / self.daysPerPeriod) + 1)
    end

    self.currentPeriod = period
    self.yearCounter   = year
    self.monthCounter  = year * PERIODS_PER_YEAR + (period - 1)
    self.seeded        = true
end

function TimeGuard:_subscribeCalendar()
    if self.messagesBound or g_messageCenter == nil then
        return
    end
    -- Target is prepended as the callback's self, so pass (method, self).
    g_messageCenter:subscribe(MessageType.DAY_CHANGED,    self.onDayChanged,    self)
    g_messageCenter:subscribe(MessageType.PERIOD_CHANGED, self.onPeriodChanged, self)
    g_messageCenter:subscribe(MessageType.HOUR_CHANGED,   self.onHourChanged,   self)
    self.messagesBound = true
end

-- =========================================================
-- Calendar event handlers
-- =========================================================

function TimeGuard:onHourChanged()
    self:_fireTick("hour")
end

function TimeGuard:onDayChanged()
    self:_fireTick("day")
    self:_settleIfServer("day")
end

function TimeGuard:onPeriodChanged()
    -- A period is a month. Advance the monotonic month counter and detect a
    -- year rollover from the period wrapping (12 -> 1). currentYear/currentPeriod
    -- are read as the authoritative correction when available.
    local env = self:_env()
    local newPeriod = (env and env.currentPeriod) or ((self.currentPeriod % PERIODS_PER_YEAR) + 1)
    local rolledYear = newPeriod <= self.currentPeriod

    self.monthCounter = self.monthCounter + 1
    if rolledYear then
        self.yearCounter = self.yearCounter + 1
    end
    self.currentPeriod = newPeriod

    self:_fireTick("month")
    self:_settleIfServer("month")

    if rolledYear then
        self:_fireTick("year")
        self:_settleIfServer("year")
    end

    -- Push the canonical counters to clients when NetworkSync is present.
    local ns = self:_getNetworkSync()
    if ns ~= nil and g_currentMission ~= nil and g_currentMission:getIsServer() then
        ns:markDirty(TimeGuard.LEDGER_MODULE)
    end
end

function TimeGuard:_settleIfServer(cadence)
    if not self.enabled then
        return
    end
    if g_currentMission == nil or not g_currentMission:getIsServer() then
        return
    end
    self.scheduler:settle(cadence)
end

-- =========================================================
-- Counters + context (read by the scheduler and consumers)
-- =========================================================

---@param cadence string  "day" | "month" | "year"
---@return number|nil
function TimeGuard:getCounter(cadence)
    if cadence == "day" then
        local env = self:_env()
        return env and env.currentMonotonicDay or nil
    elseif cadence == "month" then
        return self.monthCounter
    elseif cadence == "year" then
        return self.yearCounter
    end
    return nil
end

function TimeGuard:getNormalizationFactor()
    return TimeGuard.REFERENCE_DAYS_PER_PERIOD / self.daysPerPeriod
end

-- Scale a CALENDAR-rated per-day rate so a whole month is burden-invariant.
-- Usage/event flows should NOT be normalized.
function TimeGuard:normalizePerDay(rate)
    if type(rate) ~= "number" then return rate end
    return rate * self:getNormalizationFactor()
end

function TimeGuard:_dayInPeriod()
    local env = self:_env()
    if env ~= nil and env.getDayInPeriodFromDay ~= nil and env.currentMonotonicDay ~= nil then
        local ok, v = pcall(env.getDayInPeriodFromDay, env, env.currentMonotonicDay)
        if ok and type(v) == "number" then return v end
    end
    return 1
end

-- Remaining fraction of the current period, for a prorated first settle.
function TimeGuard:getPeriodRemainingFraction(cadence)
    local env = self:_env()
    local dayTime = (env and env.dayTime) or 0
    local dayFrac = (DAY_MS - dayTime) / DAY_MS       -- fraction of the current day left
    if cadence == "day" then
        return math.max(0, math.min(1, dayFrac))
    elseif cadence == "month" then
        local dip = self:_dayInPeriod()               -- 1..daysPerPeriod
        local remaining = (self.daysPerPeriod - dip) + dayFrac
        return math.max(0, math.min(1, remaining / self.daysPerPeriod))
    elseif cadence == "year" then
        local monthsLeft = (PERIODS_PER_YEAR - self.currentPeriod) + self:getPeriodRemainingFraction("month")
        return math.max(0, math.min(1, monthsLeft / PERIODS_PER_YEAR))
    end
    return 1.0
end

function TimeGuard:getContext()
    local env = self:_env()
    return {
        period             = self.currentPeriod,
        year               = self.yearCounter,
        monthCounter       = self.monthCounter,
        monotonicDay       = (env and env.currentMonotonicDay) or 0,
        dayInPeriod        = self:_dayInPeriod(),
        daysPerPeriod      = self.daysPerPeriod,
        normalizationFactor = self:getNormalizationFactor(),
        synced             = self.synced,
    }
end

-- The context handed to a settle callback (a fresh table; settle adds fields).
function TimeGuard:buildSettleContext(cadence)
    local ctx = self:getContext()
    ctx.cadence = cadence
    return ctx
end

-- =========================================================
-- Tick subscriptions (display/read; all peers)
-- =========================================================

---@param event string    "hour" | "day" | "month" | "year"
---@param id string        stable subscriber id
---@param callback function callback(ctx)
function TimeGuard:subscribeTick(event, id, callback)
    if self.tickSubs[event] == nil then
        TGLogger.warning("subscribeTick: unknown event '%s'", tostring(event))
        return false
    end
    if type(id) ~= "string" or id == "" or type(callback) ~= "function" then
        TGLogger.warning("subscribeTick('%s'): needs a string id and a function", tostring(event))
        return false
    end
    if self.tickSubs[event][id] == nil then
        table.insert(self.tickSubOrder[event], id)
        table.sort(self.tickSubOrder[event])   -- deterministic fire order
    end
    self.tickSubs[event][id] = callback
    return true
end

function TimeGuard:unsubscribeTick(event, id)
    if self.tickSubs[event] ~= nil then
        self.tickSubs[event][id] = nil
    end
end

function TimeGuard:_fireTick(event)
    local subs = self.tickSubs[event]
    if subs == nil then return end
    local ctx = self:buildSettleContext(event == "hour" and "day" or event)
    ctx.tickEvent = event
    for _, id in ipairs(self.tickSubOrder[event]) do
        local cb = subs[id]
        if cb ~= nil then
            local ok, err = pcall(cb, ctx)
            if not ok then
                TGLogger.error("tick subscriber '%s' (%s) failed: %s", id, event, tostring(err))
            end
        end
    end
end

-- =========================================================
-- Accrual API (delegates to the scheduler)
-- =========================================================

function TimeGuard:registerAccrual(id, spec)
    return self.scheduler:registerAccrual(id, spec)
end

-- =========================================================
-- Bedrock binding (delegate-when-present, idempotent)
-- =========================================================

function TimeGuard:_getLedger()
    return (g_currentMission ~= nil and g_currentMission.stateLedger) or g_stateLedger
end

function TimeGuard:_getNetworkSync()
    return (g_currentMission ~= nil and g_currentMission.networkSync) or g_networkSync
end

function TimeGuard:_getSettingsHub()
    return (g_currentMission ~= nil and g_currentMission.settingsHub) or g_settingsHub
end

function TimeGuard:_bindBedrock()
    if self.bedrockBound then
        return
    end

    local ledger = self:_getLedger()
    if ledger ~= nil and not self.ledgerBound then
        ledger:registerModule(TimeGuard.LEDGER_MODULE, {
            serialize   = function() return self.scheduler:serializeCursors() end,
            deserialize = function(data)
                self.scheduler:deserializeCursors(data)
                self.ledgerRestored = true
            end,
        })
        self.ledgerBound = true
    end

    local ns = self:_getNetworkSync()
    if ns ~= nil and not self.networkSyncBound then
        ns:registerModule(TimeGuard.LEDGER_MODULE, {
            channel      = "TimeGuard_Sync",
            onWriteState = function() return self:_onWriteContextState() end,
            onReadState  = function(arr) self:_onReadContextState(arr) end,
        })
        self.networkSyncBound = true
    end

    local hub = self:_getSettingsHub()
    if hub ~= nil and not self.settingsHubBound then
        hub:registerModule(TimeGuard.LEDGER_MODULE, {
            selfPersisted = true,   -- TimeGuard owns self.enabled; hub is a mirror
            adminSettings = {
                { id = "enabled", type = "bool", default = true, adminOnly = true,
                  label = "Time Guard Enabled" },
            },
            onChange = function(key, value)
                if key == "enabled" then
                    self.enabled = value ~= false
                end
            end,
        })
        self.settingsHubBound = true
    end

    -- Only mark bound when ALL available services have been registered.
    -- If a service isn't available yet, keep retrying on next update tick.
    local allAvailable = (ledger ~= nil and self.ledgerBound)
                     and (ns ~= nil and self.networkSyncBound)
                     and (hub ~= nil and self.settingsHubBound)
    if allAvailable or (self.ledgerBound and self.networkSyncBound and self.settingsHubBound) then
        self.bedrockBound = true
    end
end

-- NetworkSync: server flattens the canonical counters; client applies them.
function TimeGuard:_onWriteContextState()
    return { self.monthCounter, self.yearCounter, self.currentPeriod, self.daysPerPeriod }
end

function TimeGuard:_onReadContextState(arr)
    if type(arr) ~= "table" or #arr < 4 then return end
    self.monthCounter  = arr[1] or self.monthCounter
    self.yearCounter   = arr[2] or self.yearCounter
    self.currentPeriod = arr[3] or self.currentPeriod
    self.daysPerPeriod = arr[4] or self.daysPerPeriod
    if self.daysPerPeriod < 1 then self.daysPerPeriod = 1 end
    self.synced = true
end

-- =========================================================
-- Own-file persistence fallback (only when StateLedger is absent)
-- =========================================================

function TimeGuard:_saveFilePath()
    if g_currentMission == nil or g_currentMission.missionInfo == nil
        or g_currentMission.missionInfo.savegameDirectory == nil then
        return nil
    end
    return g_currentMission.missionInfo.savegameDirectory .. "/" .. TimeGuard.SAVE_FILE
end

function TimeGuard:_saveOwnFile()
    local path = self:_saveFilePath()
    if path == nil then return end
    local xml = XMLFile.create("tg_CursorsXML", path, "timeGuard")
    if xml == nil then return end
    local cursors = self.scheduler:serializeCursors()
    local i = 0
    for id, rec in pairs(cursors) do
        local key = string.format("timeGuard.accrual(%d)", i)
        xml:setString(key .. "#id", id)
        xml:setInt(key .. "#cursor", math.floor(rec.cursor or 0))
        xml:setBool(key .. "#settledOnce", rec.settledOnce == true)
        if rec.firstProration ~= nil then
            xml:setFloat(key .. "#firstProration", rec.firstProration)
        end
        i = i + 1
    end
    xml:save()
    xml:delete()
end

function TimeGuard:_loadOwnFile()
    local path = self:_saveFilePath()
    if path == nil then return end
    local xml = XMLFile.loadIfExists("tg_CursorsXML", path, "timeGuard")
    if xml == nil then return end
    local data = {}
    xml:iterate("timeGuard.accrual", function(_, key)
        local id = xml:getString(key .. "#id")
        if id ~= nil then
            data[id] = {
                cursor         = xml:getInt(key .. "#cursor", 0),
                settledOnce    = xml:getBool(key .. "#settledOnce", false),
                firstProration = xml:getFloat(key .. "#firstProration", nil),
            }
        end
    end)
    xml:delete()
    self.scheduler:deserializeCursors(data)
end

-- =========================================================
-- Console command (tgStatus)
-- =========================================================

function TimeGuard:consoleCommandStatus()
    local role = "unknown"
    if g_currentMission ~= nil then
        role = g_currentMission:getIsServer() and "server" or "client"
    end
    local lines = {}
    table.insert(lines, string.format("Time Guard: role=%s, enabled=%s, synced=%s, bedrock=%s",
        role, tostring(self.enabled), tostring(self.synced), tostring(self.bedrockBound)))
    table.insert(lines, string.format("  clock: year=%d period=%d/%d daysPerPeriod=%d monthCounter=%d monotonicDay=%s norm=%.3f",
        self.yearCounter, self.currentPeriod, PERIODS_PER_YEAR, self.daysPerPeriod,
        self.monthCounter, tostring(self:getCounter("day")), self:getNormalizationFactor()))
    for _, line in ipairs(self.scheduler:getStatusLines()) do
        table.insert(lines, line)
    end
    return table.concat(lines, "\n")
end
