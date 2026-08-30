# assets/authored/car/explosion -- WS51 Car Explosion Model

**Owner:** WS51 Car Explosion Model
**Branch:** `ws51-explosion`
**Source:** Authored placeholder -- deterministic shockwave core scaled to PhysicsConstants (1 unit = 1 m).

## Contents

| File | Description | Source |
|------|-------------|--------|
| `car_explosion_core_a_v01.glb` | Explosion core placeholder mesh (single body, 1 material, ~1.8k tris, <12 draw calls) | Authored box mesh triangulated, scale 1.0, Y-up +Z forward, radius 6.0 m derived from CAR_LENGTH 4.2 |

## Conventions

- Centered at origin, Y-up, right-handed, 1 unit = 1 m.
- Dimensions derived from `src/core/constants.gd` and `src/game/car/supersonic.gd` thresholds (WS25): SUPERSONIC 18 m/s, DEMO_IMPACT 10 m/s.
- Duration 1.5 s, respawn 3.0 s matches `SupersonicRef.DEMO_RESPAWN_TIME`.
- No procedural generation at runtime -- all geometry authored and committed.
- Triangulated, scale 1.0, <12 draw calls, <300k tris.
- Git LFS: tracked via `.gitattributes` (`assets/authored/** filter=lfs`).
- Deterministic: clean clone + Godot 4.x import = identical render.
- Budget: <12 calls per tick, 120 Hz tick (physics/common/physics_ticks_per_second).

## Model

Logic in `src/game/car/explosion_model.gd` (class `CarExplosion`):

- `EXPLOSION_DURATION` 1.5 s, `EXPLOSION_RADIUS` 6.0 m, `SHOCKWAVE_SPEED` 4.0 m/s, `HIDE_DELAY` 0.08 s, `RESPAWN_TIME` 3.0 s.
- Uses `SupersonicRef.can_demo()` for eligibility -- supersonic (18) + impact >10.
- `physics_tick(car, delta)` advances timer, returns VFX visibility; <12 calls.
- Validated via `CarExplosion.debug_validate()` against `PhysicsConstants` and `SupersonicRef`.
