# Changelog

All notable changes to FS25_TimeGuard will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Changelog tracking for this mod begins **2026-08-22** under the suite-wide ruling
(see the ecosystem ledger, entry for Arissani and Wizard). Prior history lives in
the repo's git history and README.

---

## [Unreleased]

## [1.0.2.0] - 2026-09-18

### Fixed
- `registerAccrual` now rejects a missing or unknown cadence outright, instead of silently defaulting to a daily cadence. A caller that omitted or mistyped `cadence` could previously have its accrual settle far more often than intended (IMPL-002).

## [1.0.1.0] - 2026-08-26

### Added
- The `simulation` flow class for non-money state accruals, alongside the existing `calendar` class.

### Fixed
- TG-002: a scheduler hook could stack on itself across a mission reload.
- TG-003: `_bindBedrock` could report completion prematurely and kill its own retry loop.
- Hot-reload conformance, suite-edit and vehicle input fixes from the 2026-08-22 conformance pass.
- README corrected to name the real `subscribeTick` events instead of the earlier placeholder names.

## [1.0.0.0] - 2026-07-17

- First entry under changelog tracking. Time Guard ships as the ecosystem's fifth core service: the shared economic clock (hour/day/month/year ticks, an accrue-and-settle scheduler, normalization, and bedrock bridges to StateLedger, NetworkSync and SettingsHub).
