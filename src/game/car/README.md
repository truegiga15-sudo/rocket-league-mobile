# src/game/car — Car Physics & Presentation

**Owner:** WS11 Car Chassis (lead), WS12 Suspension, WS13 Friction, WS14 Engine, WS15 Steering/Drift, WS16 Jump, WS17 Dodge, WS18 Boost, WS24 Air Control, WS25 Supersonic/Demo, WS46-WS55 Meshes & Garage
**Branches:** `ws11-*`…`ws18-*`, `ws24-*`, `ws25-*`, `ws46-*`…`ws55-*`

## Ownership Map
| File / Scene | Owner WS | Branch |
|---|---|---|
| `car_chassis.tscn/.gd` | WS11 | `ws11-car-chassis` |
| `suspension.gd`, `wheel_raycast.gd` | WS12 | `ws12-suspension` |
| `tire_friction.gd` | WS13 | `ws13-tire-friction` |
| `engine_curve.gd` | WS14 | `ws14-engine-curve` |
| `steering.gd`, `drift.gd` | WS15 | `ws15-steering-drift` |
| `jump.gd` | WS16 | `ws16-jump` |
| `dodge.gd` | WS17 | `ws17-dodge-flip` |
| `boost_system.gd` | WS18 | `ws18-boost-system` |
| `air_control.gd` | WS24 | `ws24-air-control` |
| `supersonic.gd`, `demo.gd` | WS25 | `ws25-supersonic-demo` |
| `octane.tscn`, `dominus.tscn`, `car_shader.tres` | WS46-WS48 | `ws46-*`… |

## Rules
- Raycast suspension, not rigid wheels. Import `src/core/physics/layers.gd`.
- Units: meters, 1 unit = 1 m, car length ~4.2 m, ball diameter 1.82 m.
- No raw `Input` — read `InputService` only.
- Authored meshes in `assets/authored/car_octane/` etc., LFS if >50 MB.
