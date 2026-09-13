-- scheduler_cadence_test.lua
-- F132 / API-7: registerAccrual must REJECT a missing or unknown cadence instead
-- of silently defaulting it to "day". A monthly fee that fell through to "day"
-- would be charged 30x. We drive the REAL scheduler with a fake clock that
-- keeps independent day and month counters, so a wrongly-defaulted accrual
-- would visibly settle on the day tick.
--!load: src/Logger.lua, src/TimeGuardScheduler.lua

-- Fake TimeGuard clock: independent monotonic counters per cadence.
local function newFakeClock()
  local clock = { day = 10, month = 2, year = 1 }
  clock.getCounter = function(self, cadence)
    return self[cadence]
  end
  clock.buildSettleContext = function(_, cadence)
    return { cadence = cadence, boundariesCrossed = 0 }
  end
  clock.getPeriodRemainingFraction = function(_, _cadence)
    return 0.5
  end
  return clock
end

local function countAccruals(scheduler)
  local n = 0
  for _ in pairs(scheduler.accruals) do n = n + 1 end
  return n
end

local function lastWarning()
  return LogCapture.warning[#LogCapture.warning]
end

-- (a) nil cadence: rejected, warned, no record added, no settlement on any tick.
do
  LogCapture.reset()
  local clock = newFakeClock()
  local scheduler = TimeGuardScheduler.new(clock)
  local settled = 0
  local ok = scheduler:registerAccrual("Fee_nil_cadence", {
    onSettle = function() settled = settled + 1 end,
  })
  T.eq("nilCadence.returnsFalse", ok, false)
  T.eq("nilCadence.noRecord", countAccruals(scheduler), 0)
  T.eq("nilCadence.orderEmpty", #scheduler.order, 0)
  T.ok("nilCadence.warned", lastWarning() ~= nil and lastWarning():find("cadence is required", 1, true) ~= nil,
    "expected a 'cadence is required' warning, got " .. tostring(lastWarning()))
  clock.day = 40
  scheduler:settle("day")
  clock.month = 3
  scheduler:settle("month")
  T.eq("nilCadence.neverSettles", settled, 0)
end

-- (b) unknown cadence "week": rejected, warned, no record added.
do
  LogCapture.reset()
  local clock = newFakeClock()
  local scheduler = TimeGuardScheduler.new(clock)
  local settled = 0
  local ok = scheduler:registerAccrual("Fee_week", {
    cadence = "week",
    onSettle = function() settled = settled + 1 end,
  })
  T.eq("weekCadence.returnsFalse", ok, false)
  T.eq("weekCadence.noRecord", countAccruals(scheduler), 0)
  T.ok("weekCadence.warned", lastWarning() ~= nil and lastWarning():find("unknown cadence 'week'", 1, true) ~= nil,
    "expected an unknown-cadence warning, got " .. tostring(lastWarning()))
  clock.day = 40
  scheduler:settle("day")
  T.eq("weekCadence.neverSettles", settled, 0)
end

-- (c) "month" is accepted and settles only on the month counter. Thirty day
-- ticks must not touch it (that is the 30x bug the default-to-day path caused).
do
  LogCapture.reset()
  local clock = newFakeClock()
  local scheduler = TimeGuardScheduler.new(clock)
  local settled, lastCtx = 0, nil
  local ok = scheduler:registerAccrual("Fee_month", {
    cadence = "month",
    firstPeriodPolicy = "skip",
    onSettle = function(ctx) settled = settled + 1; lastCtx = ctx end,
  })
  T.eq("monthCadence.returnsTrue", ok, true)
  T.eq("monthCadence.noWarning", #LogCapture.warning, 0)
  local a = scheduler.accruals["Fee_month"]
  T.ok("monthCadence.recorded", a ~= nil, "accrual not registered")
  T.eq("monthCadence.storedCadence", a and a.cadence, "month")

  -- Seed the cursor on the month tick (policy skip => cursor = current month).
  scheduler:settle("month")
  T.eq("monthCadence.seedNoCharge", settled, 0)
  T.eq("monthCadence.cursorSeeded", a.cursor, 2)

  -- Thirty day boundaries pass: nothing may settle.
  for d = 11, 40 do
    clock.day = d
    scheduler:settle("day")
  end
  T.eq("monthCadence.dayTicksIgnored", settled, 0)
  T.eq("monthCadence.cursorUntouchedByDays", a.cursor, 2)

  -- One month boundary: exactly one settlement, one boundary crossed.
  clock.month = 3
  scheduler:settle("month")
  T.eq("monthCadence.settledOnce", settled, 1)
  T.eq("monthCadence.boundariesCrossed", lastCtx and lastCtx.boundariesCrossed, 1)
  T.eq("monthCadence.ctxCadence", lastCtx and lastCtx.cadence, "month")
  T.eq("monthCadence.cursorAdvanced", a.cursor, 3)

  -- Same counter again: idempotent, no double settle.
  scheduler:settle("month")
  T.eq("monthCadence.idempotent", settled, 1)
end

-- (d) deserializeCursors before registration creates a placeholder (cadence "day",
-- onSettle nil). A later registerAccrual with "month" must overwrite the cadence,
-- keep the persisted cursor, and never double-settle the restored position.
do
  LogCapture.reset()
  local clock = newFakeClock()
  local scheduler = TimeGuardScheduler.new(clock)

  scheduler:deserializeCursors({
    Fee_reload = { cursor = 2, settledOnce = true, firstProration = 1.0 },
  })
  local placeholder = scheduler.accruals["Fee_reload"]
  T.ok("reload.placeholderCreated", placeholder ~= nil, "placeholder missing")
  T.eq("reload.placeholderUnbound", placeholder and placeholder.onSettle, nil)
  T.eq("reload.placeholderCursor", placeholder and placeholder.cursor, 2)

  -- The placeholder carries cadence "day" but no callback, so a day tick past
  -- its cursor must not settle anything (settle() skips onSettle == nil).
  local settled = 0
  clock.day = 40
  scheduler:settle("day")
  T.eq("reload.placeholderNeverSettles", settled, 0)

  local ok = scheduler:registerAccrual("Fee_reload", {
    cadence = "month",
    firstPeriodPolicy = "skip",
    onSettle = function() settled = settled + 1 end,
  })
  T.eq("reload.registerReturnsTrue", ok, true)
  local a = scheduler.accruals["Fee_reload"]
  T.eq("reload.cadenceOverwritten", a.cadence, "month")
  T.eq("reload.cursorKept", a.cursor, 2)
  T.eq("reload.settledOnceKept", a.settledOnce, true)

  -- Same month as the persisted cursor: nothing due (no re-settle of the past).
  scheduler:settle("month")
  T.eq("reload.noDoubleSettle", settled, 0)

  -- Day ticks still ignored now that it is bound as month.
  clock.day = 70
  scheduler:settle("day")
  T.eq("reload.dayTicksIgnored", settled, 0)

  -- Next month boundary settles exactly once.
  clock.month = 3
  scheduler:settle("month")
  T.eq("reload.settlesNextMonth", settled, 1)
  T.eq("reload.cursorAdvanced", a.cursor, 3)

  -- Persisted view still carries the month cursor, not a day cursor.
  local out = scheduler:serializeCursors()
  T.eq("reload.serializedCursor", out.Fee_reload and out.Fee_reload.cursor, 3)
end
