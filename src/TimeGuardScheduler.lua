-- =========================================================
-- FS25_TimeGuard - accrue-and-settle scheduler
-- =========================================================
-- Author: TisonK
-- =========================================================
-- Holds the registered accruals and settles them on the economic ticks. The
-- hard invariants (this is money-adjacent, so they are the cert gate):
--
--   * NEVER writes money. It only invokes the owner's onSettle callback; the
--     owner does its own admin-gated, server-authoritative money write.
--   * Server only. TimeGuard gates the tick before calling settle().
--   * Idempotent across save/load. Each accrual carries a monotonic "cursor"
--     (the last boundary index it settled) that is persisted; on reload the
--     cursor is restored and any boundaries crossed since are caught up.
--   * Catch-up, no forfeit. A skip/time-warp that crosses several boundaries
--     in one frame settles each of them (the callback receives boundariesCrossed).
--   * Deterministic order. Accruals settle in (priority, id) order, never pairs().
--   * Never double-settles. cursor == currentCounter => nothing due.
--
-- A "counter" is a monotonic boundary index for a cadence: day = the engine's
-- currentMonotonicDay; month/year = counters TimeGuard maintains from
-- PERIOD_CHANGED. The scheduler reads them through the clock reference.
-- =========================================================

TimeGuardScheduler = TimeGuardScheduler or {}
local TimeGuardScheduler_mt = Class(TimeGuardScheduler)

TimeGuardScheduler.CADENCES = { day = true, month = true, year = true }
TimeGuardScheduler.FLOW_CLASSES = { calendar = true, usage = true, event = true, simulation = true }
TimeGuardScheduler.FIRST_POLICIES = { prorate = true, full = true, skip = true }

function TimeGuardScheduler.new(clock)
    local self = setmetatable({}, TimeGuardScheduler_mt)
    self.clock    = clock   -- the TimeGuard instance (counter + context source)
    self.accruals = {}      -- id -> accrual record
    self.order    = {}      -- ids sorted by (priority, id) for deterministic settle
    return self
end

-- =========================================================
-- Registration
-- =========================================================

---@param id string   stable id: mod + farm + purpose, e.g. "TaxMod_annual_farm1"
---@param spec table   { cadence="day"|"month"|"year", flowClass, firstPeriodPolicy, priority, onSettle }
---@return boolean success
function TimeGuardScheduler:registerAccrual(id, spec)
    if type(id) ~= "string" or id == "" then
        TGLogger.warning("registerAccrual: invalid id '%s', ignoring", tostring(id))
        return false
    end
    if type(spec) ~= "table" or type(spec.onSettle) ~= "function" then
        TGLogger.warning("registerAccrual('%s'): needs { onSettle = fn, ... }, ignoring", id)
        return false
    end

    local cadence = spec.cadence or "day"
    if not TimeGuardScheduler.CADENCES[cadence] then
        TGLogger.warning("registerAccrual('%s'): unknown cadence '%s', defaulting to day", id, tostring(cadence))
        cadence = "day"
    end
    local flowClass = spec.flowClass or "calendar"
    if not TimeGuardScheduler.FLOW_CLASSES[flowClass] then
        TGLogger.warning("registerAccrual('%s'): unknown flowClass '%s', defaulting to calendar", id, tostring(flowClass))
        flowClass = "calendar"
    end
    local firstPolicy = spec.firstPeriodPolicy or "prorate"
    if not TimeGuardScheduler.FIRST_POLICIES[firstPolicy] then
        firstPolicy = "prorate"
    end

    -- Re-registration (e.g. after reload) keeps the persisted cursor + settledOnce
    -- so the same id re-matches its saved position and never re-settles the past.
    local existing = self.accruals[id]
    self.accruals[id] = {
        id                = id,
        cadence           = cadence,
        flowClass         = flowClass,
        firstPeriodPolicy = firstPolicy,
        priority          = tonumber(spec.priority) or 100,
        onSettle          = spec.onSettle,
        cursor            = existing and existing.cursor or nil,           -- nil = seed on first tick
        settledOnce       = (existing and existing.settledOnce) or false,
        firstProration    = existing and existing.firstProration or nil,
    }

    self:_rebuildOrder()
    TGLogger.debug("Registered accrual '%s' (cadence=%s, flow=%s, policy=%s, prio=%d)",
        id, cadence, flowClass, firstPolicy, self.accruals[id].priority)
    return true
end

function TimeGuardScheduler:_rebuildOrder()
    self.order = {}
    for id in pairs(self.accruals) do
        self.order[#self.order + 1] = id
    end
    table.sort(self.order, function(a, b)
        local pa, pb = self.accruals[a].priority, self.accruals[b].priority
        if pa ~= pb then return pa < pb end
        return a < b   -- id tiebreak => fully deterministic across peers and reloads
    end)
end

---@param id string  stable accrual id
---@return boolean success
function TimeGuardScheduler:unregisterAccrual(id)
    if type(id) ~= "string" or id == "" then
        return false
    end
    if self.accruals[id] == nil then
        return false
    end
    self.accruals[id] = nil
    self:_rebuildOrder()
    TGLogger.debug("Unregistered accrual '%s'", id)
    return true
end

-- =========================================================
-- Cursor seeding (first observation of an accrual)
-- =========================================================
-- Seed a fresh accrual's cursor so it never settles the past. Policy:
--   skip           -> cursor = current  (the partial current period is not charged;
--                     the first settle is the next full boundary)
--   full / prorate -> cursor = current-1 (the next boundary settles the first period;
--                     prorate stores the remaining fraction of the current period)
function TimeGuardScheduler:_seedCursor(a, currentCounter)
    if a.firstPeriodPolicy == "skip" then
        a.cursor = currentCounter
    else
        a.cursor = currentCounter - 1
        if a.firstPeriodPolicy == "prorate" then
            a.firstProration = self.clock:getPeriodRemainingFraction(a.cadence)
        else
            a.firstProration = 1.0
        end
    end
end

-- =========================================================
-- Settlement (server only; TimeGuard gates before calling)
-- =========================================================

---Settle every accrual of the given cadence up to the current boundary counter.
---@param cadence string
function TimeGuardScheduler:settle(cadence)
    local currentCounter = self.clock:getCounter(cadence)
    if currentCounter == nil then
        return
    end

    for _, id in ipairs(self.order) do
        local a = self.accruals[id]
        if a ~= nil and a.cadence == cadence and a.onSettle ~= nil then
            if a.cursor == nil then
                self:_seedCursor(a, currentCounter)
            end

            if a.cursor < currentCounter then
                local boundaries = currentCounter - a.cursor
                local ctx = self.clock:buildSettleContext(cadence)
                ctx.accrualId        = id
                ctx.boundariesCrossed = boundaries
                ctx.isFirstSettle    = not a.settledOnce
                ctx.proration        = 1.0
                if not a.settledOnce and a.firstPeriodPolicy == "prorate" then
                    ctx.proration = a.firstProration or 1.0
                end

                local ok, err = pcall(a.onSettle, ctx)
                if ok then
                    a.cursor       = currentCounter
                    a.settledOnce  = true
                else
                    -- Keep the cursor where it was so the next tick retries; never
                    -- advance past a failed settlement (no forfeit, no double-charge).
                    TGLogger.error("accrual '%s' onSettle failed: %s (will retry)", id, tostring(err))
                end
            end
        end
    end
end

-- =========================================================
-- Persistence (id -> cursor). StateLedger serialize/deserialize, or own XML.
-- =========================================================

-- Returns a plain table { id = { cursor, settledOnce, firstProration } } for the
-- registered accruals that have a live cursor. Ids that never ticked are omitted.
function TimeGuardScheduler:serializeCursors()
    local out = {}
    for _, id in ipairs(self.order) do
        local a = self.accruals[id]
        if a ~= nil and a.cursor ~= nil then
            out[id] = { cursor = a.cursor, settledOnce = a.settledOnce, firstProration = a.firstProration }
        end
    end
    return out
end

-- Restore cursors. May run before OR after an accrual has registered; a record is
-- created/updated for each id so a later registerAccrual re-matches by id.
function TimeGuardScheduler:deserializeCursors(data)
    if type(data) ~= "table" then
        return
    end
    for id, saved in pairs(data) do
        if type(id) == "string" and type(saved) == "table" then
            local a = self.accruals[id]
            if a == nil then
                a = { id = id, cadence = "day", flowClass = "calendar",
                      firstPeriodPolicy = "prorate", priority = 100, onSettle = nil }
                self.accruals[id] = a
            end
            a.cursor         = tonumber(saved.cursor) or a.cursor
            a.settledOnce    = saved.settledOnce == true or a.settledOnce == true
            a.firstProration = tonumber(saved.firstProration) or a.firstProration
        end
    end
    self:_rebuildOrder()
    TGLogger.debug("Restored %d accrual cursor(s)", (function() local n=0 for _ in pairs(data) do n=n+1 end return n end)())
end

-- =========================================================
-- Introspection
-- =========================================================

function TimeGuardScheduler:getStatusLines()
    local lines = {}
    table.insert(lines, string.format("  accruals: %d", #self.order))
    for _, id in ipairs(self.order) do
        local a = self.accruals[id]
        table.insert(lines, string.format("    - %s (cadence=%s, flow=%s, prio=%d, cursor=%s, bound=%s)",
            id, a.cadence, a.flowClass, a.priority, tostring(a.cursor),
            tostring(a.onSettle ~= nil)))
    end
    return lines
end
