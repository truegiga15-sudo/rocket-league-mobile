# src/core — Shared Foundation (WS01, WS04-WS10)

**Owner:** WS01 Repo/Branch CI, WS04 Units, WS05 Time/Determinism, WS07 Physics Layers, WS08 Save, WS09 Telemetry, WS10 Perf Budgets
**Branch:** `ws01-*`, `ws04-*`…`ws10-*` (shared — requires RFC)
**Depends on:** none (foundation)

## Purpose
Authoritative core singletons and constants imported by every downstream workstream. No gameplay logic here.

## Contents
- `constants.gd` — units, scale, physics constants (WS04)
- `physics/layers.gd`, `physics/constants.gd` — collision layers (WS07)
- `time/` — fixed tick 120 Hz, determinism, delta clamping 1/240..1/30 (WS05)
- `input/input_service.gd` — InputService singleton abstraction (WS06 spec lives here, impl in WS06)
- `save/save_service.gd` — SaveService JSON+checksum at `user://save.json` (WS08)
- `telemetry/` — debug_export, perf_mark, replay log (WS09)
- `perf/budgets.gd` — draw call / tris / texture budgets (WS10)

## Rules
- **Shared ownership — RFC required.** Any change needs review from dependent WS owners.
- No `src/game/*`, `src/render/*` imports — core must have zero downstream dependencies.
- Exports: `PhysicsConstants`, `InputService`, `TimeService`, `SaveService`, `AudioService`, `Telemetry` (§15 conventions).
- Naming: `snake_case` files, `PascalCase` scenes if any, nodes `Type_Name`.

## Verification
```bash
python3 tools/validate_naming.py --check src/core
```
