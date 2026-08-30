# docs/architecture/physics-layers.md — WS07 Physics Conventions & Collision Layers

**Owner:** WS07 Physics Conventions & Collision Layers  
**Branch:** `ws07-physics-layers`  
**Depends on:** WS04 Coordinate/Units (1 m = 1 unit, Y-up, right-handed), WS05 Fixed tick 120 Hz  
**Sources of truth:** `src/core/physics/layers.gd`, `src/core/physics/physics_config.gd` (import these; never re-declare)

## 1. Layers (Godot 3D physics, indices 0-5)

Godot exposes 32 collision layers. This project uses **6** — indices 0-5. In the editor they appear as layers 1-6; in code they are 0-indexed bits (`1 << layer`). Always use `PhysicsLayers` constants.

| Index | Name           | Godot bit | Type        | Description |
|------:|----------------|----------:|-------------|-------------|
| 0     | `world_static` | `1` (1<<0) | StaticBody3D / CollisionShape3D | Floor, walls, ceiling, arena collision mesh. Authored, not procedural. |
| 1     | `car_chassis`  | `2` (1<<1) | RigidBody3D  | Car hitbox (Octane-like 4.2×2.1×1.5 m). Mass 180 kg. |
| 2     | `wheels`       | `4` (1<<2) | Raycast proxies | Suspension raycasts — **not** rigid wheels. Query only world. |
| 3     | `ball`         | `8` (1<<3) | RigidBody3D  | Sphere 1.82 m diameter, 30 kg, CCD enabled. |
| 4     | `boost_pads`   | `16` (1<<4)| Area3D      | Boost pad triggers (big pads 100%, small 12%). Detect `car_chassis`. |
| 5     | `sensors`      | `32` (1<<5)| Area3D      | Goal volume, out-of-bounds, kickoff triggers. Detect `ball` + `car_chassis`. |

Bits 6-31 are **reserved / unused**. Do not assign gameplay layers above 5 without an RFC.

### Editor mapping (project.godot)

```ini
[layer_names]
3d_physics/layer_1="world_static"
3d_physics/layer_2="car_chassis"
3d_physics/layer_3="wheels"
3d_physics/layer_4="ball"
3d_physics/layer_5="boost_pads"
3d_physics/layer_6="sensors"
```

Indices 0-5 map to `layer_1`..`layer_6` in this section.

## 2. Default collision matrix

"Masks" are *which layers this layer collides with / scans*. Triggers (4, 5) have no physics response — their mask means "which bodies overlap this Area".

| Layer | Mask (bits) | Mask (names) | Rationale |
|-------|-------------|--------------|-----------|
| 0 world_static | `car_chassis \| ball` | `car_chassis\|ball` | Solid ground/walls for cars and ball. Wheel raycasts query this layer separately. |
| 1 car_chassis  | `world_static \| car_chassis \| ball` | `world_static\|car_chassis\|ball` | Car-vs-world, car-vs-car (demo), car-vs-ball impulse. No trigger layers. |
| 2 wheels       | `world_static` | `world_static` | Raycasts hit only world — never cars/ball/pads. Friction curves in WS13. |
| 3 ball         | `world_static \| car_chassis` | `world_static\|car_chassis` | Ball bounces off world and gets hit by cars. CCD on. |
| 4 boost_pads   | `car_chassis` | `car_chassis` | Area detects car entry to recharge boost. |
| 5 sensors      | `ball \| car_chassis` | `ball\|car_chassis` | Goal/OOB detection for ball and cars. |

Full mask `MASK_ALL = 0b111111 = 63`. Use `PhysicsLayers.DEFAULT_MASKS[layer]` or `default_mask_for_layer(layer)`.

```
        0  1  2  3  4  5
      +--+--+--+--+--+--+
 0 WS |  ·  X  ·  X  ·  · |
 1 CC |  X  X  ·  X  ·  · |
 2 WH |  X  ·  ·  ·  ·  · |  (raycast query, not rigid)
 3 BA |  X  X  ·  ·  ·  · |
 4 BP |  · (X) ·  ·  ·  · |  (Area overlap, not solid)
 5 SE |  · (X) · (X) ·  · |  (Area overlap, not solid)
      +--+--+--+--+--+--+
```

## 3. Helpers (src/core/physics/layers.gd)

```gdscript
const PL = preload("res://src/core/physics/layers.gd")

# Bits / masks
var bit := PL.layer_bit(PL.LAYER_BALL)          # 8
var mask := PL.mask_for_layers([PL.LAYER_WORLD_STATIC, PL.LAYER_BALL])  # 0b1001
var mask2 := PL.mask_for(PL.LAYER_WORLD_STATIC, PL.LAYER_BALL)          # same
var has := PL.mask_has(mask, PL.LAYER_BALL)     # true
var name := PL.layer_name(PL.LAYER_SENSORS)     # "sensors"

# Defaults
var default_mask := PL.default_mask_for_layer(PL.LAYER_CAR_CHASSIS)
var names := PL.mask_to_names(default_mask)     # "world_static|car_chassis|ball"
var valid := PL.is_valid_mask(63)               # true

# Godot node setup
$CarBody.collision_layer = PL.BIT_CAR_CHASSIS
$CarBody.collision_mask  = PL.MASK_CAR_CHASSIS
$BallBody.collision_layer = PL.BIT_BALL
$BallBody.collision_mask  = PL.MASK_BALL
$BoostPadArea.collision_layer = PL.BIT_BOOST_PADS
$BoostPadArea.collision_mask  = PL.MASK_BOOST_PADS  # which bodies trigger it
```

Additional helpers: `masks_overlap(a, b)`, `is_valid_layer(l)`, `all_layers()`, `debug_export()`, `perf_mark()`.

## 4. Physics config (src/core/physics/physics_config.gd)

All tuning lives in `PhysicsConfig` — never hardcode elsewhere.

| Parameter | Value | Notes |
|-----------|-------|-------|
| Gravity | `9.81 m/s²` (`GRAVITY_EARTH × GRAVITY_SCALE`, `-Y`) | Earth default; `GRAVITY_SCALE=1.0`. RL-tuned alt `GRAVITY_RL_TUNED=13.5` for experiments. Vector `GRAVITY_VECTOR = (0, -9.81, 0)`. |
| Tick | `120 Hz`, `delta 1/120 ≈ 0.00833 s` | Mirrors `project.godot` `physics/common/physics_ticks_per_second`. Delta clamped `1/240..1/30` (WS05). |
| Solver | `iterations 12`, `velocity 8`, `bias 0.3` | Jolt/Bullet wrapper at 120 Hz; stays within `physics < 4 ms` budget (WS10). |
| Friction | `default 0.8`, `world-car 0.9`, `world-ball 0.6`, `car-ball 0.3` | Tire curves in WS13; car-ball kept low so ball slides. |
| Restitution | `default 0.4`, `world-ball 0.75`, `car-ball 0.85`, `world-car 0.15` | Punchy ball hits, dead car-vs-wall. |
| Mass | `car 180 kg`, `ball 30 kg` | RL-like impulse ratios. |
| Damping | `car lin 0.15 ang 0.35`, `ball lin 0.08 ang 0.12` | Prevents infinite roll/spin. |
| Sleep | `lin 0.1 m/s`, `ang 0.1 rad/s`, `time 0.5 s` | Lets resting bodies sleep to save ms. |
| CCD | Ball enabled, threshold `0.5 m` | Prevents tunneling at high speed. |

```gdscript
const PC = preload("res://src/core/physics/physics_config.gd")
PhysicsServer3D.set_active(true)
# Gravity is set on World3D / PhysicsServer, not per-body:
# In a scene: world_3d.space -> gravity vector; or per-body:
$BallBody.gravity_scale = 1.0  # uses world gravity (9.81)
var g: Vector3 = PC.gravity_vector(1.15)  # heavier variant for tuning
```

Validation: `PhysicsConfig.debug_validate() -> {ok, errors}`. Telemetry: `debug_export()`, `perf_mark()`.

## 5. Rules for downstream WS

1. **Import, don't redeclare.** `preload("res://src/core/physics/layers.gd")` and `physics_config.gd`. Never `const LAYER_BALL = 3` locally.
2. **No rigid wheels.** Wheels are raycasts (WS12) on layer 2 querying layer 0 only. Never add a `CylinderShape3D` wheel body.
3. **Triggers are Areas, not solids.** Boost pads (4) and sensors (5) are `Area3D` with monitors; set their `collision_mask` to the bodies they detect.
4. **Ball is a sphere.** `SphereShape3D` radius `0.91 m` (from `PhysicsConstants.BALL_RADIUS`), CCD on, continuous.
5. **Determinism.** Fixed tick 120 Hz, quantized inputs, no frame-dependent forces. See WS05.
6. **Perf budget.** `physics < 4 ms` per frame. Solver 12/8 stays within budget; raise only with measurement.
7. **No procedural geometry.** Arena collision mesh is authored and committed under `assets/authored/` (WS36/WS21).

## 6. Verification

```bash
python3 tools/validate_naming.py --check src/core/physics
# Godot headless (if available):
godot --headless --script src/core/physics/layers.gd --check-only
```

Expected: `layers.gd` exports 6 layers, `MASK_ALL == 63`, `physics_config.gd` `GRAVITY == 9.81`, solver `12/8`.

## 7. Provenance

Gravity 9.81 m/s² = earth standard; RL in-engine 650 uu/s² maps to ~13.5 m/s² at our meter scale — provided as `GRAVITY_RL_TUNED` for A/B tuning with the blind harness (WS99). Friction/restitution/solvers are Jolt defaults tuned at 120 Hz to meet the `< 4 ms` physics budget on mid devices.
