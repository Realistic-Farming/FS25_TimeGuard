# FS25_TimeGuard

**Realistic Farming - Time Guard** is the shared economic-time authority for the Realistic Farming mod ecosystem. It is the 5th core service, alongside StateLedger, NetworkSync, MasterHUD, and SettingsHub.

**Version:** 1.0.0.0

## What it does

The economy mods (IncomeMod, TaxMod, WorkerCosts, FuelCosts, MarketDynamics, RandomWorldEvents) each used to hand-roll their own "has the day/month turned?" detector off the frame loop, only one respected the days-per-month setting, and their accrual basis was inconsistent. Time Guard replaces those private clocks with one:

- It fires on the game's in-game calendar events (`MessageType.DAY_CHANGED` / `PERIOD_CHANGED` / `HOUR_CHANGED`) and republishes canonical economic ticks (`"hour"` / `"day"` / `"month"` / `"year"`) that every economic mod subscribes to via `subscribeTick` (see Public surface below).
- It normalizes the days-per-month setting in ONE place, so a game month, and therefore a year, carries the same economic weight on any save.
- It holds an accrue-and-settle scheduler that invokes each owning mod's settlement callback once, at the right calendar moment, idempotent across save/load.

## The money-safety fence

Time Guard **never writes money**. It is a scheduler, not a money mover. On a settle tick it invokes the owning mod's callback (once, server-side, idempotent); the owner performs its own admin-gated, server-authoritative money write. Time Guard owns CADENCE (when money moves and the once-only guarantee), never MAGNITUDE (how much).

## Handles

```
g_currentMission.timeGuard   -- cross-mod handle, set in Mission00.load, nil on delete
g_timeGuard                  -- getfenv(0) same-mod fallback for early-load access
```

Consumers bind through the mission handle, pcall-wrapped, neutral when absent:

```lua
local tg = (g_currentMission ~= nil and g_currentMission.timeGuard) or g_timeGuard
```

## Public surface

- `tg:subscribeTick(event, id, callback)` — `event` is `"hour"|"day"|"month"|"year"`; callback receives the tick context. Display/read subscribers fire on all peers.
- `tg:registerAccrual(id, spec)` — `spec = { flowClass = "calendar"|"usage"|"event"|"simulation", firstPeriodPolicy = "prorate"|"full"|"skip", priority = number, onSettle = function(ctx) ... end }`. The callback runs server-only, once per crossed boundary, and does its own money write. `simulation` is for non-money state evolution (day-cadence work that must survive skipped days with no forfeit); nothing that writes money may ever register under it.
- `tg:normalizePerDay(rate)` — scale a calendar-rated per-day rate by days-per-month. Usage/event flows are not normalized.
- `tg:getContext()` — the current calendar context (period, year, days-per-month, days elapsed in period, normalization factor, synced flag).

## Core API connections (delegate-when-present, neutral when absent)

- **StateLedger** — persists the accrual cursors when present; own XML fallback (`RealisticFarming_TimeGuard.xml`) when absent.
- **NetworkSync** — syncs the published context to clients when present; `synced=false` neutral when absent.
- **SettingsHub** — the admin `enabled` toggle via `registerModule`.
- **MasterHUD** — not required (no overlay); FarmTablet reads the context directly.

## Console command

- `tgStatus` — show the clock state, tick subscribers, and registered accruals.

## Multiplayer

All settlement runs on the server. Clients read a present handle with `synced=false` over zeroed context until NetworkSync delivers the snapshot. Ticks may fire client-side for display; settlement never does.

Zero Precision Farming dependence. 26 languages for any player-facing string.
