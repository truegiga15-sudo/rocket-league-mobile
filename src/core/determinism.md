# Determinism — WS05 Time Step & Determinism
> **Owner:** WS05 — **Depends on:** WS04
> **Spec:** `docs/architecture/00-conventions.md §3`, `src/core/constants.gd`, `src/core/time_service.gd`
Fixed-tick determinism guarantees same replay log at 120 Hz produces bit-identical simulation.

## 1. Fixed-Tick Rules
| Rule | Value | Notes |
|------|-------|-------|
| Physics rate | **120 Hz** | `physics/common/physics_ticks_per_second = 120` |
| Fixed delta | `TICK_DELTA = 1.0 / 120.0` | All physics steps use this exact value |
| Delta clamp | `[DELTA_MIN, DELTA_MAX] = [1/240, 1/30]` | `TimeService.clamp_delta()` |
| Accumulator | `accumulator += clamp_delta(raw_delta); while accumulator >= TICK_DELTA: step()` | `TimeService.advance(delta)` |
| Spiral guard | `MAX_TICKS_PER_FRAME = 4` | At most 4 ticks per frame |
| Render alpha | `alpha = accumulator / TICK_DELTA` | Interpolation only |
| Total time | `total_time = tick_count * TICK_DELTA` | Monotonic simulation clock |

Pseudocode:
```gdscript
var svc := TimeService
func _process(raw_delta: float) -> void:
	var ticks: int = svc.advance(raw_delta)
	for i in ticks: physics_step(TimeService.TICK_DELTA, svc.get_tick_count())
	interpolate_render(svc.get_alpha())
```

Startup & suspend: `TimeService.reset()` on match start; on suspend do not feed large gap as one delta — call `reset()` or single `DELTA_MAX`.

## 2. Input Quantization
- **Resolution:** `INPUT_QUANT_STEPS = 127` per half-range. LSB ≈ 0.00787.
- **Per axis:** `q = round(clamp(v, -1, 1) * 127)` → int `[-127,127]`. Dequantize: `v' = q / 127.0`.
- **Per vector:** `Vector2i(qx, qy)` via `quantize_vector2` / `dequantize_vector2`.
- **Booleans:** stored as `0/1`.
Helpers in `TimeService`: `quantize_axis`, `dequantize_axis`, `quantize_vector2`, `dequantize_vector2`, `quantize_input`, `dequantize_input`.
Round-trip error ≤ `0.5/127 ≈ 0.00394`.

## 3. Replay Log Format
### Envelope
```json
{
  "version": 1,
  "meta": {"ticks_per_second": 120, "tick_delta": 0.008333333333333333, "quant_steps": 127, "created_at": 1724470000, "match_id": "ws05_smoke_001", "map": "dfh_stadium"},
  "ticks": [{"tick": 0, "t": 0.0, "move_x": 0, "move_y": 0, "look_x": 0, "look_y": 0, "boost": 0, "jump": 0, "drift": 0, "ball_cam": 1}]
}
```
| Field | Type | Notes |
|-------|------|-------|
| `version` | int | `1` |
| `meta.ticks_per_second` | int | Must be `120` |
| `meta.quant_steps` | int | `127` |
| `tick` | int | Authoritative, `t == tick * tick_delta` |
| `move_x`, `move_y`, `look_x`, `look_y` | int | `[-127,127]` |
| `boost`, `jump`, `drift`, `ball_cam` | int | `0/1` |

Each fixed tick appends exactly one entry. Validation: contiguous ticks, `t ≈ tick*1/120`, range checks.

## 4. Checklist
- [ ] Physics uses `TICK_DELTA` only
- [ ] Input quantized via `TimeService.quantize_input`
- [ ] No `randf()` inside tick — seeded RNG keyed by `tick_count`
- [ ] `project.godot: physics_ticks_per_second` is `120`
