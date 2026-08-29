# src/game — Gameplay Logic

**Owner:** Aggregate — see subdirectories for per-WS ownership
**Branches:** `ws11-*`…`ws25-*` (physics), `ws36-*`…`ws68-*` (arena/ball/VFX)

## Subdirectories
- `car/` — WS11-WS18, WS24-WS25, WS46-WS55 (chassis, suspension, boost, meshes)
- `ball/` — WS19-WS20, WS56-WS57 (ball physics, prediction)
- `arena/` — WS21-WS22, WS36-WS45 (collision, stadium, goals, pads)
- `rules/` — (future) WS58-WS60 match rules, kickoff, replays — create when WS58 starts

Game code depends on `src/core` only. VFX/Audio depend on game events, never direct physics.
