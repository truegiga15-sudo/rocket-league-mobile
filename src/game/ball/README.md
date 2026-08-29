# src/game/ball — Ball Physics & Presentation

**Owner:** WS19 Ball Physics (lead), WS20 Ball-Car Contact, WS56 Ball Mesh, WS57 Prediction
**Branches:** `ws19-*`, `ws20-*`, `ws56-*`, `ws57-*`

## Ownership Map
| File / Scene | Owner WS | Branch |
|---|---|---|
| `ball.tscn`, `ball_physics.gd` | WS19 | `ws19-ball-physics` |
| `ball_contact.gd`, `impulse_transfer.gd` | WS20 | `ws20-ball-contact` |
| `ball_mesh.tscn`, `ball_trail.gd` | WS56 | `ws56-ball-mesh` |
| `prediction_line.gd` | WS57 | `ws57-prediction` |

## Rules
- Mass, bounce, spin authored per WS19 spec; contact impulse via WS20.
- Ball has no skeleton. Trail/VFX authored assets in `assets/authored/ball/`.
