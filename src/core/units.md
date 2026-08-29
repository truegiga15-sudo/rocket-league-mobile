# WS04 — Coordinate, Units & Scale Conventions

> **Authority:** This document + `src/core/constants.gd` are the single source of truth for all workstreams.
> Do not duplicate scale values elsewhere; `import`/`preload` `constants.gd`.

## 1. Basis

| Axis | Direction | Notes |
|------|-----------|-------|
| **+X** | Right (east) | Lateral |
| **+Y** | Up | `UP = Vector3(0,1,0)` |
| **+Z** | Forward (south) | Default facing; `FORWARD = Vector3(0,0,1)` |

- **Handedness:** Right-handed.
- **Up axis:** Y (Godot 4.x default).
- **Origin:** Arena center at `Vector3.ZERO`. Floor at `Y=0`.
- **Forward:** `+Z` is canonical forward (toward positive-Z goal). Use `PhysicsConstants.FORWARD`.

Rules:
- All world positions are right-handed Y-up `Vector3`.
- No Z-up or left-handed helpers. Convert at the boundary if an asset arrives Z-up.
- Rotations in radians; `Basis`/`Quaternion` follow Godot's right-handed convention.

## 2. Units

- **1 unit = 1 meter.**
- `UNITS_PER_METER = 1.0`, `METERS_PER_UNIT = 1.0`.
- Helpers: `PhysicsConstants.meters_to_units(m)` / `units_to_meters(u)` (identity today, future-proof).
- All distances, sizes, speeds (`m/s`), and forces are authored in meters.

## 3. Time

- **Fixed physics tick:** `120 Hz` — `project.godot` → `physics/common/physics_ticks_per_second = 120`.
- `PHYSICS_TICK_DELTA = 1/120 ≈ 0.008333s`.
- Variable render delta clamped to `[1/240, 1/30]` per `00-conventions.md` §3.
- No frame-dependent physics.

## 4. Scale Reference (meters)

### Car (Octane-like hitbox)

| Dim | Value | Notes |
|-----|-------|-------|
| Length (Z) | **4.2 m** | Bumper-to-bumper |
| Width (X)  | **2.1 m** | Mirror-to-mirror |
| Height (Y) | **1.5 m** | Roof height |
| Half extents | `Vector3(2.1, 0.75, 1.05)` mapped as `(X=WIDTH/2, Y=HEIGHT/2, Z=LENGTH/2)` | `CAR_HALF_EXTENTS` |

### Ball

| Dim | Value |
|-----|-------|
| Diameter | **1.82 m** |
| Radius   | **0.91 m** |
| Circumference | `π × 1.82 ≈ 5.72 m` |

### Arena (playable volume, centered at origin)

| Dim | Value | Derived |
|-----|-------|---------|
| Length (Z, goal-to-goal) | **60.0 m** | `HALF_LENGTH = 30.0` |
| Width (X, side-to-side)  | **40.0 m** | `HALF_WIDTH = 20.0` |
| Height (Y, floor-to-ceiling) | **20.0 m** | `HALF_HEIGHT = 10.0` (ceiling at `Y=20`) |
| Size `Vector3` | `(40, 20, 60)` | X=width, Y=height, Z=length |
| AABB | `AABB(Vector3(-20,0,-30), Vector3(40,20,60))` | Floor at `Y=0` |

### Goal (RL standard, scaled 1:1)

| Dim | Value |
|-----|-------|
| Width (X opening) | **7.3 m** |
| Height (Y opening)| **2.1 m** |
| Depth (Z behind line) | **2.0 m** |
| Center Y | `1.05 m` |
| Centers | `(0, 1.05, ±30.0)` |

Goal tests: `PhysicsConstants.goal_aabb(is_positive_z)` / `is_inside_goal(point, is_positive_z)`.

## 5. Helpers in `constants.gd`

- `car_size()`, `car_half_extents()`, `car_aabb(center)`
- `arena_aabb()`, `is_inside_arena(point)`, `clamp_to_arena(point)`
- `world_to_arena_uv(point) -> Vector2` (XZ floor projection, `[0,1]`)
- `arena_uv_to_world(uv, y) -> Vector3`
- `goal_center(is_positive_z)`, `goal_aabb(is_positive_z)`, `is_inside_goal(point, is_positive_z)`
- `debug_validate() -> {ok, errors}` — self-check used by `coordinate_test.gd`.

## 6. Usage

```gdscript
const PC = preload("res://src/core/constants.gd")

func _ready():
    var pos := Vector3(5, 0.5, -10) # meters
    assert(PC.is_inside_arena(pos))
    var uv := PC.world_to_arena_uv(pos)
    var back := PC.arena_uv_to_world(uv, pos.y)
```

## 7. Provenance

- Car/ball/arena/goal values: RL community hitbox + field dimensions scaled 1:1 (meters).
- Coordinate choice: Godot 4.x default (Y-up, right-handed) with `+Z` forward pinned by this WS.
